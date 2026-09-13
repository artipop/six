import Foundation

/// WebMCP's page half: a polyfill for `document.modelContext`, and the few lines six runs to call a
/// tool through it. JavaScript in string literals, and — like `TranslationScript` — the same text
/// on every front, which is why it is in `SixCore`. docs/webmcp.md is the plan it answers to.
///
/// **This runs in the page's own world, and that is the second deliberate exception** after
/// `PageInstrumentation`. Everything else six injects lives in a content world of its own so a page
/// cannot see it; but the whole point here is that the page's scripts call `registerTool`, and an
/// object in six's world is one they cannot reach. So the consequences are the ones capture already
/// states: the page can see the polyfill, replace it, and post to its channel directly. The
/// channel's name changes every launch, and what a forged message can buy is spelled out on
/// `WebMCPMessage` — a tool of the page's own, which `registerTool` gives it anyway.
///
/// **The function never leaves the page.** `registerTool` keeps `execute` in a closure here and
/// sends Swift the description. A call is Swift asking the polyfill to start the tool and the
/// polyfill posting the answer back over the same channel — two moves rather than one, because a
/// tool is asynchronous and `WebPage.callJavaScript` has never been measured to wait on a promise
/// (CLAUDE.md: no `await` in its bodies). Posting back works the same on every engine six runs on,
/// so the Windows front's self-test drives exactly the path the Mac takes.
nonisolated enum WebMCPScript {
    /// The channel's name — different every launch, so a page cannot count on finding it.
    static let handlerName = "six" + token()
    /// Where the call bodies below find the polyfill. On `window`, because they run in the page's
    /// world too; a page that finds it can start its own tools with it and nothing else.
    static let bridgeKey = "__six" + token()

    private static func token() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())
    }

    /// A function body that starts a call and returns at once; the answer arrives as a `result`
    /// message. The arguments travel as a JSON *string* and are parsed in the page, so no difference
    /// between JavaScript's literal syntax and JSON's can reach the tool.
    static func startBody(call: String, tool: String, arguments: ACPJSON) -> String {
        let input = (try? JSONEncoder().encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
            const bridge = window.\(bridgeKey);
            if (!bridge) { throw new Error('there is no WebMCP polyfill in this page: it has navigated, or it is not a secure context'); }
            return bridge.start(\(literal(call)), \(literal(tool)), \(literal(input)));
            """
    }

    /// Fires the call's `AbortSignal` in the page. Harmless for a call that has already ended.
    static func cancelBody(call: String, reason: String) -> String {
        """
        const bridge = window.\(bridgeKey);
        if (bridge) { bridge.cancel(\(literal(call)), \(literal(reason))); }
        return true;
        """
    }

    /// Which document the page is showing, as the polyfill stamps its messages — empty when there is
    /// no polyfill there. What a front asks after a navigation (`WebMCPRegistry.settle`).
    static let documentQuery = "const bridge = window.\(bridgeKey); return bridge ? bridge.doc : '';"

    /// A Swift string as a JavaScript string literal. JSON's string syntax is JavaScript's, except
    /// that engines before ES2019 read U+2028 and U+2029 as line ends.
    static func literal(_ text: String) -> String {
        let encoded = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return encoded
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The polyfill: a `WKUserScript` at document start, main frame only.
    static var source: String {
        #"""
        (function () {
            'use strict';
            // The main frame only. The draft lets a frame in through the `tools` permissions policy,
            // and six has not built that half (docs/webmcp.md, stage 3).
            if (window.top !== window) { return; }
            const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(handlerName);
            if (!channel) { return; }
            // Taken now, before any of the page's own scripts has run and could replace them.
            const stringify = JSON.stringify;
            const parse = JSON.parse;
            const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
            const post = (message) => {
                message.doc = doc;
                try { channel.postMessage(stringify(message)); } catch (e) {}
            };

            // First, and whatever happens next: this window shows a new document. A page that gets
            // no modelContext below still has to take the previous page's tools away with it.
            post({ kind: 'document', url: String(location.href) });

            // `[SecureContext]` in the draft. And a page that already has one — a native
            // implementation, one day — keeps it; the draft's own polyfills check for this too.
            if (!window.isSecureContext) { return; }
            if ('modelContext' in document || 'modelContext' in navigator) { return; }

            const NAME = /^[A-Za-z0-9_.-]{1,128}$/;
            const origin = String(location.origin);
            const tools = new Map();   // name -> entry; the entry holds execute, which never leaves
            const calls = new Map();   // call id -> AbortController, for the calls six started
            let onToolChange = null;

            const say = (error) => {
                if (error && typeof error === 'object' && 'message' in error) {
                    return (error.name ? error.name + ': ' : '') + String(error.message);
                }
                if (typeof error === 'string') { return error; }
                try { return stringify(error); } catch (e) { return String(error); }
            };

            const describe = (entry) => ({
                name: entry.name, title: entry.title, description: entry.description,
                inputSchema: entry.inputSchema, annotations: entry.annotations, origin
            });

            const announce = (entry) => post({ kind: 'register', origin, tool: describe(entry) });

            const changed = (context) => {
                try { context.dispatchEvent(new Event('toolchange')); } catch (e) {}
            };

            function validate(tool) {
                if (!tool || typeof tool !== 'object') {
                    throw new TypeError('registerTool: the tool must be an object');
                }
                if (typeof tool.name !== 'string' || !NAME.test(tool.name)) {
                    throw new TypeError('registerTool: a tool name is 1 to 128 of A-Z a-z 0-9 _ . -');
                }
                if (typeof tool.description !== 'string') {
                    throw new TypeError('registerTool: description must be a string');
                }
                if (typeof tool.execute !== 'function') {
                    throw new TypeError('registerTool: execute must be a function');
                }
                let inputSchema = { type: 'object', properties: {} };
                if (tool.inputSchema !== undefined && tool.inputSchema !== null) {
                    if (typeof tool.inputSchema !== 'object') {
                        throw new TypeError('registerTool: inputSchema must be an object');
                    }
                    try { inputSchema = parse(stringify(tool.inputSchema)); } catch (e) {
                        throw new TypeError('registerTool: inputSchema must be JSON');
                    }
                }
                const hints = tool.annotations || {};
                return {
                    name: tool.name,
                    tool,
                    execute: tool.execute,
                    title: typeof tool.title === 'string' ? tool.title : '',
                    description: tool.description,
                    inputSchema,
                    annotations: {
                        readOnlyHint: !!hints.readOnlyHint,
                        untrustedContentHint: !!hints.untrustedContentHint,
                        consequentialHint: !!hints.consequentialHint
                    },
                    provided: false
                };
            }

            // What a tool returned, as the draft's DOMString. A page written for the first origin
            // trial returns MCP's own CallToolResult — `{ content: [{ type: 'text', text }] }` —
            // and is read as what it meant, not as a JSON object an agent then has to unwrap.
            function serialize(value) {
                if (value === undefined || value === null) { return ''; }
                if (typeof value === 'string') { return value; }
                if (typeof value === 'object' && Array.isArray(value.content)) {
                    const text = value.content
                        .map((part) => part && part.type === 'text' ? String(part.text) : stringify(part))
                        .join('\n');
                    if (value.isError) { throw new Error(text || 'the tool reported an error'); }
                    return text;
                }
                try { return stringify(value); } catch (e) { return String(value); }
            }

            async function run(name, input, signal) {
                const entry = tools.get(name);
                if (!entry) { throw new DOMException('No tool named ' + name, 'NotFoundError'); }
                if (signal && signal.aborted) { throw signal.reason; }
                // The draft's second argument is `{ signal }`. `requestUserInteraction` is the first
                // trial's, kept because pages written for it call it; six has nothing to put in
                // front of the person yet (stage 3), so the callback simply runs.
                const options = { signal, requestUserInteraction: (callback) => Promise.resolve().then(callback) };
                const value = await entry.execute.call(entry.tool, input === undefined || input === null ? {} : input, options);
                return serialize(value);
            }

            function remove(context, entry) {
                if (tools.get(entry.name) !== entry) { return; }
                tools.delete(entry.name);
                post({ kind: 'unregister', name: entry.name });
                changed(context);
            }

            // The first trial's `registerTool` answered `{ unregister() }` rather than a promise,
            // and sites built then still call it that way. One object can be both.
            const withUnregister = (promise, unregister) => { promise.unregister = unregister; return promise; };

            class ModelContext extends EventTarget {
                registerTool(tool, options) {
                    let entry;
                    try { entry = validate(tool); } catch (error) {
                        return withUnregister(Promise.reject(error), () => {});
                    }
                    const signal = options && options.signal;
                    if (signal && signal.aborted) { return withUnregister(Promise.resolve(), () => {}); }
                    if (tools.has(entry.name)) {
                        return withUnregister(Promise.reject(new DOMException(
                            'A tool named ' + entry.name + ' is already registered', 'InvalidStateError')), () => {});
                    }
                    tools.set(entry.name, entry);
                    announce(entry);
                    changed(this);
                    const unregister = () => remove(this, entry);
                    if (signal) { signal.addEventListener('abort', unregister, { once: true }); }
                    return withUnregister(Promise.resolve(), unregister);
                }

                getTools(options) {
                    const from = options && Array.isArray(options.fromOrigins) ? options.fromOrigins : null;
                    if (from && !from.includes(origin)) { return Promise.resolve([]); }
                    return Promise.resolve(Array.from(tools.values(), describe));
                }

                executeTool(tool, input, options) {
                    const name = tool && typeof tool === 'object' ? tool.name : tool;
                    return run(String(name), input, options && options.signal);
                }

                get ontoolchange() { return onToolChange; }
                set ontoolchange(handler) {
                    if (onToolChange) { this.removeEventListener('toolchange', onToolChange); }
                    onToolChange = typeof handler === 'function' ? handler : null;
                    if (onToolChange) { this.addEventListener('toolchange', onToolChange); }
                }

                // The first origin trial's surface, on the same object: `navigator.modelContext`
                // was deprecated in Chrome 150, and the sites that shipped against it have not all
                // moved. docs/webmcp.md says when to take this out.
                unregisterTool(name) {
                    const entry = tools.get(String(name));
                    if (entry) { remove(this, entry); }
                }
                provideContext(context) {
                    for (const entry of Array.from(tools.values())) {
                        if (entry.provided) { remove(this, entry); }
                    }
                    for (const tool of (context && context.tools) || []) {
                        this.registerTool(tool).catch(() => {});
                        const entry = tool && tools.get(tool.name);
                        if (entry && entry.tool === tool) { entry.provided = true; }
                    }
                }
                clearContext() {
                    for (const entry of Array.from(tools.values())) { remove(this, entry); }
                }
            }

            const context = new ModelContext();
            for (const target of [document, navigator]) {
                try {
                    Object.defineProperty(target, 'modelContext', { value: context, configurable: true, enumerable: true });
                } catch (e) {}
            }

            Object.defineProperty(window, '\#(bridgeKey)', {
                value: Object.freeze({
                    doc,
                    start(call, name, inputText) {
                        let input = {};
                        try { input = inputText ? parse(inputText) : {}; } catch (e) {}
                        const controller = new AbortController();
                        calls.set(call, controller);
                        run(String(name), input, controller.signal).then(
                            (text) => { calls.delete(call); post({ kind: 'result', call, ok: true, value: text }); },
                            (error) => { calls.delete(call); post({ kind: 'result', call, ok: false, error: say(error) }); });
                        return true;
                    },
                    cancel(call, reason) {
                        const controller = calls.get(call);
                        if (controller) {
                            calls.delete(call);
                            controller.abort(new DOMException(reason || 'Cancelled', 'AbortError'));
                        }
                        return true;
                    }
                })
            });

            // A page restored from the back-forward cache is the same document, but six forgot its
            // tools when the window left it. So it says everything again.
            window.addEventListener('pageshow', (event) => {
                if (!event.persisted) { return; }
                post({ kind: 'document', url: String(location.href) });
                for (const entry of tools.values()) { announce(entry); }
            });
        })();
        """#
    }
}
