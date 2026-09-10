import Foundation

/// The page half of Bergamot: the document six loads off-screen, and the script that drives the
/// engine inside it.
///
/// It is written the way `TranslationScript` is — JavaScript in string literals, `Foundation` and
/// nothing else — and for the same reason: this text is the contract, and the Linux front, the
/// Windows front and anything after them run *this exact text*. What differs between them is how a
/// function gets called in a page, which is `PageSandbox` and is four lines each.
///
/// Almost everything below is a transcription of Firefox's `translations-engine.worker.js`, which
/// is the only working account of how to drive this wasm module: the heap alignments per file kind,
/// the Marian config, the vector-of-messages calling convention, and the `delete()` after every
/// allocation — embind hands out raw heap and JavaScript's collector knows nothing about it, so a
/// missed `delete` is thirty megabytes leaked per language switch.
nonisolated enum BergamotDriver {

    /// The page. Deliberately empty: it is never shown, never painted, and never navigated
    /// anywhere. Its whole job is to be an origin that can `fetch` the files beside it and a
    /// JavaScript context that outlives one call.
    static let page = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>six — Bergamot</title>
    <script src="bergamot-translator.js"></script>
    <script src="six-bergamot.js"></script>
    </head>
    <body></body>
    </html>
    """#

    static let source = #"""
    "use strict";

    // six's driver for bergamot-translator. Loaded beside Emscripten's own glue, which defines the
    // global `loadBergamot`. Everything here answers in one shape — `{}` for success, `{error}` for
    // failure — because a JavaScript exception crossing a WebKit script bridge arrives in Swift as
    // "a JavaScript exception occurred" with the message stripped off, and the message is the only
    // part worth having.

    // On `window` rather than a lexical `const`: a script bridge that evaluates in an isolated
    // world would not see the second, and which world a front calls into is the front's business.
    window.sixBergamot = (function () {
        // Each kind of model file has to land in the wasm heap at a particular alignment. These are
        // the engine's, not the record's: nothing in Remote Settings says them.
        const ALIGNMENTS = { model: 256, lex: 64, vocab: 64, srcvocab: 64, trgvocab: 64 };

        let engine = null;          // the wasm Module, made once and kept for the life of the page
        let service = null;         // BlockingService
        let models = [];            // one TranslationModel, or two when pivoting through English
        let allocated = [];         // every AlignedMemory handed to those models

        async function bytes(path) {
            const response = await fetch(path);
            if (!response.ok) throw new Error("cannot read " + path + " (" + response.status + ")");
            return await response.arrayBuffer();
        }

        // Marian reads its settings as YAML, and it is particular about the indentation.
        function config(entries) {
            const indent = "            ";
            let text = "\n";
            for (const key of Object.keys(entries)) text += indent + key + ": " + entries[key] + "\n";
            return text + indent;
        }

        function start(wasmBinary) {
            return new Promise(function (resolve, reject) {
                // Forty megabytes to begin with, and it grows. Emscripten's heap is never given
                // back, so starting small and growing costs less than one generous guess.
                const module = loadBergamot({
                    INITIAL_MEMORY: 41943040,
                    print: function () {},
                    printErr: function () {},
                    onAbort: function () { reject(new Error("the Bergamot engine could not start")); },
                    onRuntimeInitialized: async function () {
                        // One microtask, so that `module` is assigned before anyone reads it.
                        await Promise.resolve();
                        resolve(module);
                    },
                    wasmBinary: wasmBinary
                });
            });
        }

        function release() {
            for (const model of models) { try { model.delete(); } catch (e) {} }
            for (const memory of allocated) { try { memory.delete(); } catch (e) {} }
            models = [];
            allocated = [];
        }

        async function build(spec) {
            const aligned = {};
            for (const kind of Object.keys(spec.files)) {
                const alignment = ALIGNMENTS[kind];
                if (!alignment) throw new Error("unknown model file: " + kind);
                const buffer = await bytes(spec.files[kind]);
                const memory = new engine.AlignedMemory(buffer.byteLength, alignment);
                memory.getByteArrayView().set(new Uint8Array(buffer));
                aligned[kind] = memory;
                allocated.push(memory);
            }

            const vocabs = new engine.AlignedMemoryList();
            if (aligned.vocab) {
                vocabs.push_back(aligned.vocab);
            } else if (aligned.srcvocab && aligned.trgvocab) {
                vocabs.push_back(aligned.srcvocab);
                vocabs.push_back(aligned.trgvocab);
            } else {
                throw new Error("the model for " + spec.from + "-" + spec.to + " has no vocabulary");
            }

            const settings = config({
                "beam-size": "1",
                "normalize": "1.0",
                "word-penalty": "0",
                "max-length-break": "128",
                "mini-batch-words": "1024",
                "workspace": "128",
                "max-length-factor": "2.0",
                // The quality model is not downloaded, so it must not be asked for.
                "skip-cost": "true",
                // Zero threads means "this thread". The page is alone in its own web process and
                // there is nothing here for a worker pool to overlap with.
                "cpu-threads": "0",
                "quiet": "true",
                "quiet-translation": "true",
                "gemm-precision": spec.gemm,
                "alignment": "soft"
            });

            return new engine.TranslationModel(
                spec.from, spec.to, settings, aligned.model, aligned.lex || null, vocabs, null
            );
        }

        return {
            /// Puts a route's weights in the page, making the engine on first use.
            load: async function (request) {
                try {
                    if (!engine) {
                        engine = await start(await bytes(request.wasm));
                        service = new engine.BlockingService({ cacheSize: 0 });
                    }
                    release();
                    for (const spec of request.models) models.push(await build(spec));
                    return {};
                } catch (error) {
                    release();
                    return { error: String(error && error.message ? error.message : error) };
                }
            },

            /// One batch, in the order it arrived. Marian is given every segment at once: it batches
            /// by sentence internally, and handing it twenty short paragraphs together is several
            /// times faster than twenty calls.
            translate: async function (request) {
                if (!service || !models.length) return { error: "no language is loaded" };
                let messages = null;
                let options = null;
                let responses = null;
                try {
                    messages = new engine.VectorString();
                    options = new engine.VectorResponseOptions();
                    for (const text of request.texts) {
                        // An empty message aborts the whole batch inside Marian, so the placeholder
                        // goes in and comes back out; the caller is matching on position.
                        messages.push_back(text.length ? text : " ");
                        options.push_back({ qualityScores: false, alignment: true, html: false });
                    }
                    responses = models.length === 1
                        ? service.translate(models[0], messages, options)
                        : service.translateViaPivoting(models[0], models[1], messages, options);

                    const texts = [];
                    for (let index = 0; index < responses.size(); index++) {
                        texts.push(responses.get(index).getTranslatedText());
                    }
                    return { texts: texts };
                } catch (error) {
                    return { error: String(error && error.message ? error.message : error) };
                } finally {
                    if (messages) { try { messages.delete(); } catch (e) {} }
                    if (options) { try { options.delete(); } catch (e) {} }
                    if (responses) { try { responses.delete(); } catch (e) {} }
                }
            },

            /// Lets the weights go. The engine itself stays: it is the expensive half to make and
            /// the cheap half to keep, and a reader who translated once will translate again.
            unload: async function () {
                release();
                return {};
            }
        };
    })();
    """#
}
