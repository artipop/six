import Foundation

/// The page the embedder runs in, and the script six talks to it through.
///
/// Written to disk on every launch beside the weights, the way `BergamotRuntime` writes its own —
/// it is a couple of kilobytes of generated output, and the alternative is a version file to keep
/// in step with the one thing here that is already versioned by its folder name.
///
/// **Why a page at all.** There is no MLX off the Mac and no ONNX Runtime a Swift package could
/// link on both Windows and Linux, but every front here ships a JavaScript engine with a wasm
/// runtime in it, and transformers.js runs exactly the model the Mac runs. So the embedder is a
/// program in a page rather than a library in the process — the same bargain `PageSandbox` was
/// built for, and the second feature to take it.
///
/// **Why two scripts.** A module script is deferred and a classic one is not, so `six-embed.js`
/// (classic) is parsed first and only defines functions; the module in the page body does the
/// import and resolves the promise those functions await. Getting that the other way round means
/// `sixEmbed` does not exist yet when Swift asks for it, which reads as "the sandbox is broken"
/// rather than "the page is still loading".
nonisolated enum EmbedderDriver {
    /// `six-embed.html`. Loaded from `file:`, and everything it reaches for is relative to itself,
    /// because a Windows path is not a URL path and an absolute `file:` URL is where that
    /// difference bites.
    static let page = """
        <!doctype html>
        <meta charset="utf-8">
        <title>six embedder</title>
        <script src="six-embed.js"></script>
        <script>window.sixEmbedDtype = "DTYPE";</script>
        <script type="module">
        // The bundle is an ES module, and a static import of one from `file:` needs the front to
        // have allowed file access from file URLs on this view's preferences — which is the same
        // thing the weights below are fetched under.
        import * as transformers from "./RUNTIME/transformers.min.js";
        window.sixEmbed._arrived(transformers);
        </script>
        """

    /// `six-embed.js`. Everything Swift calls, and nothing else.
    static let source = #"""
        // The embedder, as the page sees it. Two entry points — load, embed — and both answer in
        // the one shape `PageSandbox` can carry: a JSON string with an `error` field or a result.
        //
        // Every function catches its own exceptions on purpose. A thrown JavaScript exception
        // reaches Swift as "a JavaScript exception occurred" and nothing else on at least one of
        // these engines, so a failure that says nothing is a failure nobody can act on.
        window.sixEmbed = (function () {
            let transformers = null;
            let arrived = null;
            const ready = new Promise((resolve) => { arrived = resolve; });
            let extractor = null;
            let loadedModel = "";

            function _arrived(module) {
                transformers = module;
                arrived(module);
            }

            // A thrown value, said in one line that names the thing that failed.
            //
            // `String(error)` alone loses the stack and `error.stack` alone loses the message — and
            // on this engine an ONNX session that will not start throws with an empty message and a
            // stack of minified frames, which is a failure report that says nothing at all. Both,
            // and the first few frames only, because the rest is transformers.js talking to itself.
            function describe(error) {
                if (!error) { return "the page failed without saying how"; }
                const parts = [];
                if (error.name) { parts.push(error.name); }
                if (error.message) { parts.push(error.message); }
                if (parts.length === 0) { parts.push(String(error)); }
                // The first two hundred characters of the stack, sliced rather than split on a
                // newline: this string is a JavaScript source inside a Swift raw literal, and an
                // escape that has to survive both is one more thing to get wrong for no gain.
                if (error.stack) { parts.push(String(error.stack).slice(0, 200)); }
                return parts.join(": ");
            }

            // Whether the page can read a file beside itself at all, and how big it is.
            //
            // Worth its six lines: a `file:` document that has not been allowed file access from
            // file URLs fails every one of these, and so does a wasm runtime whose own `.wasm` is
            // simply not where it was told — and both arrive at Swift as the same empty ONNX
            // failure. This says which file, and says it before the model is asked for.
            async function probe(path) {
                try {
                    const response = await fetch(path);
                    if (!response.ok) { return path + ": " + response.status; }
                    const bytes = await response.arrayBuffer();
                    return path + ": " + bytes.byteLength;
                } catch (error) {
                    return path + ": " + describe(error);
                }
            }

            // A file beside the page, as a `blob:` URL — see `load` for what that is for.
            async function blobOf(path, type) {
                const response = await fetch(path);
                if (!response.ok) { throw new Error(path + " answered " + response.status); }
                const bytes = await response.arrayBuffer();
                return URL.createObjectURL(new Blob([bytes], { type: type }));
            }

            // E5 is trained with a role on every text and is a different model without it: a
            // passage embedded as a query lands in a different part of the space. The same two
            // prefixes `MLXEmbedder` writes.
            function prefixed(texts, role) {
                const prefix = role === "query" ? "query: " : "passage: ";
                return texts.map((text) => prefix + text);
            }

            async function load(request) {
                try {
                    await ready;
                    if (loadedModel === request.model && extractor) { return { ok: true }; }
                    const env = transformers.env;
                    // Nothing is fetched from the network by the page. Six has already put the
                    // weights and the runtime on the disk, verified, and the page is not allowed
                    // to decide otherwise — a browser that quietly downloads a hundred megabytes
                    // because a cache miss looked like one is the thing this avoids.
                    env.allowRemoteModels = false;
                    env.allowLocalModels = true;
                    env.localModelPath = "./models/";
                    // The ONNX Runtime is handed to itself as two blob URLs rather than as the
                    // folder it lives in, and this is the one line in the file that had to be
                    // measured rather than reasoned about.
                    //
                    // ORT's wasm backend does not load its glue with a `<script>`: it *dynamically
                    // imports* `ort-wasm-simd-threaded.jsep.mjs` from `wasmPaths`. A module import
                    // from a `file:` document is refused by WebKit however much file access the
                    // view has been given — the static import at the top of the page works, a
                    // dynamic one does not — and what comes back is "no available backend found.
                    // ERR: [wasm] TypeError: Importing a module script failed", three layers away
                    // from anything that mentions a module. Read as text and handed back as a
                    // `blob:`, the same bytes import fine. The wasm is named explicitly beside it
                    // because the glue would otherwise resolve it against its own `import.meta.url`,
                    // which is now a blob with no folder under it.
                    env.backends.onnx.wasm.wasmPaths = {
                        mjs: await blobOf("./RUNTIME/ort-wasm-simd-threaded.jsep.mjs", "text/javascript"),
                        wasm: await blobOf("./RUNTIME/ort-wasm-simd-threaded.jsep.wasm", "application/wasm")
                    };
                    // One thread. Threads here mean SharedArrayBuffer, which means cross-origin
                    // isolation headers a `file:` page cannot have; asking for them costs a
                    // fallback with a warning rather than a failure, so the honest thing is to
                    // not ask.
                    env.backends.onnx.wasm.numThreads = 1;
                    extractor = await transformers.pipeline("feature-extraction", request.model, {
                        dtype: window.sixEmbedDtype || "q8",
                        // The one thing that has to be said out loud, and the same trap the Mac's
                        // `Pooling(strategy: .mean)` comment describes: without it the CLS vector
                        // is used and every sentence sits within a few percent of every other.
                        // `embed` passes `pooling: "mean"` per call, which is where it takes effect.
                    });
                    loadedModel = request.model;
                    return { ok: true };
                } catch (error) {
                    return { error: describe(error) };
                }
            }

            async function embed(request) {
                try {
                    if (!extractor) { return { error: "no model loaded" }; }
                    const texts = prefixed(request.texts || [], request.role);
                    if (texts.length === 0) { return { vectors: [] }; }
                    const output = await extractor(texts, { pooling: "mean", normalize: true });
                    // `output` is a Tensor of [n, dimension]. `tolist()` is the shape Swift wants
                    // and the only one that survives JSON without a byte-order argument.
                    return { vectors: output.tolist() };
                } catch (error) {
                    return { error: describe(error) };
                }
            }

            // What the page can say about itself when nothing works, so a self-test has something
            // to print other than "it failed".
            async function report(request) {
                try {
                    await ready;
                    const reachable = [];
                    for (const path of ["./RUNTIME/ort-wasm-simd-threaded.jsep.wasm",
                                        "./models/" + request.model + "/config.json",
                                        "./models/" + request.model + "/onnx/model_quantized.onnx"]) {
                        reachable.push(await probe(path));
                    }
                    return {
                        version: transformers.env.version || "?",
                        backend: JSON.stringify(transformers.env.backends.onnx.wasm.wasmPaths),
                        model: loadedModel,
                        files: reachable
                    };
                } catch (error) {
                    return { error: describe(error) };
                }
            }

            function unload() {
                extractor = null;
                loadedModel = "";
                return { ok: true };
            }

            return { _arrived, load, embed, report, unload };
        })();
        """#

    /// The two files, with the runtime folder's real name substituted in. The folder carries the
    /// version, so the page cannot be written once and left: the string it reaches for has to say
    /// which runtime this launch installed.
    static func files(runtimeFolder: String, dtype: String) -> [(name: String, contents: String)] {
        [
            ("six-embed.html", page
                .replacingOccurrences(of: "RUNTIME", with: runtimeFolder)
                .replacingOccurrences(of: "DTYPE", with: dtype)),
            ("six-embed.js", source.replacingOccurrences(of: "RUNTIME", with: runtimeFolder))
        ]
    }
}
