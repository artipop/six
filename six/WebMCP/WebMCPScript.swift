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

    /// The same, for a call one frame's `executeTool` makes to another's tool: the input arrives
    /// as the caller's JSON text.
    static func startBody(call: String, tool: String, input: String) -> String {
        """
        const bridge = window.\(bridgeKey);
        if (!bridge) { throw new Error('there is no WebMCP polyfill in this frame'); }
        return bridge.start(\(literal(call)), \(literal(tool)), \(literal(input)));
        """
    }

    /// Tells a frame that the tools it can see changed.
    static let toolChangeBody = "const bridge = window.\(bridgeKey); if (bridge) { bridge.toolchange(); } return true;"

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

    /// The polyfill: a `WKUserScript` at document start, in every frame a front injects it into.
    static var source: String {
        #"""
        (function () {
            'use strict';
            const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(handlerName);
            if (!channel) { return; }
            // Taken now, before any of the page's own scripts has run and could replace them.
            const { Promise, Map, Array, Object, String, Symbol, URL, Event, EventTarget, Document, DOMException,
                    AbortController, TypeError, Error, setTimeout, queueMicrotask } = window;
            const stringify = JSON.stringify;
            const parse = JSON.parse;
            const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
            // Where this frame sits in the page, as indices into `frames` from the top.
            const path = [];
            try {
                for (let w = window; w !== w.parent; w = w.parent) {
                    const up = w.parent;
                    let i = 0;
                    while (i < up.frames.length && up.frames[i] !== w) { i++; }
                    path.unshift(i);
                }
            } catch (e) {}
            // A channel that answers (a reply handler) is what reaches the other frames through six;
            // one that does not leaves this document on its own.
            const ask = (message) => {
                message.doc = doc;
                let answer;
                try { answer = channel.postMessage(stringify(message)); } catch (e) { return null; }
                if (!answer || typeof answer.then !== 'function') { return null; }
                return Promise.resolve(answer).then((text) => {
                    try { return text ? parse(text) : {}; } catch (e) { return {}; }
                });
            };
            const post = (message) => { ask(message); };

            // First, and whatever happens next: this frame shows a new document. A page that gets
            // no modelContext below still has to take the previous page's tools away with it.
            const brokered = !!ask({ kind: 'document', url: String(location.href), path });

            // `[SecureContext]` in the draft. And a page that already has one — a native
            // implementation, one day — keeps it; the draft's own polyfills check for this too.
            if (!window.isSecureContext) { return; }
            // An initial about:blank that navigates keeps its Window, and with it the previous
            // install; that one is replaced, anything else that got here first is left alone.
            const previous = Object.getOwnPropertyDescriptor(window, '\#(bridgeKey)');
            if (!previous && ('modelContext' in document || 'modelContext' in navigator)) { return; }
            const TARGET = Symbol('document');
            const detached = () => !document.defaultView;
            const gone = () => Promise.reject(new DOMException('the document is not active', 'InvalidStateError'));

            const NAME = /^[A-Za-z0-9_.-]{1,128}$/;
            const origin = String(location.origin);
            const tools = new Map();   // name -> entry; the entry holds execute, which never leaves
            const calls = new Map();   // call id -> AbortController, for the calls six started
            const handlers = { toolchange: null, toolactivated: null };

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

            // The schema and annotations as a page reads them back: absent when none were given.
            const asPage = (entry) => ({
                inputSchema: entry.pageSchema,
                annotations: entry.declaredAnnotations
                    ? Object.assign({}, entry.annotations, { debugging: entry.debugging }) : undefined
            });

            // `getTools()`'s RegisteredTool: the page also gets its window.
            const registered = (entry) => {
                const tool = describe(entry);
                tool.origin = String(self.origin);
                tool.window = window;
                const page = asPage(entry);
                if (page.inputSchema === undefined) { delete tool.inputSchema; } else { tool.inputSchema = page.inputSchema; }
                if (page.annotations === undefined) { delete tool.annotations; } else { tool.annotations = page.annotations; }
                return tool;
            };

            const wellFormed = (text) => typeof text.toWellFormed === 'function' ? text.toWellFormed() : text;

            // `exposedTo` takes potentially trustworthy origins only.
            function trustworthy(text) {
                let url;
                try { url = new URL(String(text)); } catch (e) { return false; }
                if (url.origin === 'null') { return false; }
                if (url.protocol === 'https:' || url.protocol === 'wss:') { return true; }
                if (url.protocol !== 'http:' && url.protocol !== 'ws:') { return false; }
                const host = url.hostname;
                return host === 'localhost' || host.endsWith('.localhost') || /^127\./.test(host) || host === '[::1]';
            }

            // A call's input goes through JSON, as the draft's does, and has to come out an object.
            function argumentsOf(input) {
                if (input === undefined) { return {}; }
                const text = stringify(input);
                if (text === undefined) { throw new TypeError('executeTool: the input is not JSON'); }
                const value = parse(text);
                if (value === null || typeof value !== 'object') {
                    throw new TypeError('executeTool: the input must be a JSON object');
                }
                return value;
            }

            const announce = (entry) => ask({
                kind: 'register', origin, tool: describe(entry), exposedTo: entry.exposedTo, page: stringify(asPage(entry))
            });

            const changed = (context) => {
                try { context.dispatchEvent(new Event('toolchange')); } catch (e) {}
            };

            function validate(tool) {
                if (!tool || typeof tool !== 'object') {
                    throw new TypeError('registerTool: the tool must be an object');
                }
                if (typeof tool.name !== 'string' || !NAME.test(tool.name)) {
                    throw new DOMException('registerTool: a tool name is 1 to 128 of A-Z a-z 0-9 _ . -', 'InvalidStateError');
                }
                if (typeof tool.description !== 'string') {
                    throw new TypeError('registerTool: description must be a string');
                }
                if (typeof tool.execute !== 'function') {
                    throw new TypeError('registerTool: execute must be a function');
                }
                let inputSchema = { type: 'object', properties: {} };
                let pageSchema;
                if (tool.inputSchema !== undefined && tool.inputSchema !== null) {
                    if (typeof tool.inputSchema !== 'object') {
                        throw new TypeError('registerTool: inputSchema must be an object');
                    }
                    let text;
                    try { text = stringify(tool.inputSchema); } catch (e) {
                        throw new TypeError('registerTool: inputSchema must be JSON');
                    }
                    if (text === undefined) { throw new TypeError('registerTool: inputSchema must be JSON'); }
                    pageSchema = parse(text);
                    // What the page gets back is what it wrote; agents need an object.
                    if (pageSchema && typeof pageSchema === 'object' && !Array.isArray(pageSchema)) { inputSchema = pageSchema; }
                }
                const hints = tool.annotations || {};
                return {
                    name: tool.name,
                    tool,
                    execute: tool.execute,
                    title: typeof tool.title === 'string' ? wellFormed(tool.title) : '',
                    description: wellFormed(tool.description),
                    declaredAnnotations: tool.annotations !== undefined && tool.annotations !== null,
                    debugging: !!hints.debugging,
                    inputSchema,
                    pageSchema,
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
                const text = stringify(value);
                if (text === undefined) { throw new TypeError('the tool answered with something that is not JSON'); }
                return text;
            }

            class ToolActivatedEvent extends Event {
                #toolName;
                constructor(type, init) {
                    super(type, init);
                    this.#toolName = init && init.toolName !== undefined ? String(init.toolName) : '';
                }
                get toolName() { return this.#toolName; }
            }

            // `toolactivated` goes to the window and to the context; `toolcancel` to the window.
            const announceCall = (type, name) => {
                const targets = type === 'toolactivated' ? [window, context] : [window];
                for (const target of targets) {
                    try { target.dispatchEvent(new ToolActivatedEvent(type, { toolName: name })); } catch (e) {}
                }
            };

            // One call, from the page's executeTool or from six. The caller's abort rejects at once
            // with its reason; the tool's own signal is aborted a task later, then `toolcancel`.
            function invoke(entry, input, callerSignal) {
                return new Promise((resolve, reject) => {
                    const inner = new AbortController();
                    let settled = false;
                    const onAbort = () => {
                        if (settled) { return; }
                        settled = true;
                        reject(callerSignal.reason);
                        setTimeout(() => {
                            inner.abort(new DOMException('The call was cancelled', 'AbortError'));
                            announceCall('toolcancel', entry.name);
                        }, 0);
                    };
                    const finish = (ok, value) => {
                        if (callerSignal) { callerSignal.removeEventListener('abort', onAbort); }
                        if (settled) { return; }
                        settled = true;
                        if (!ok) { return reject(value); }
                        try { resolve(serialize(value)); } catch (e) { reject(e); }
                    };
                    if (callerSignal) { callerSignal.addEventListener('abort', onAbort, { once: true }); }
                    // `requestUserInteraction` is the first trial's, kept because pages written for
                    // it call it; the callback simply runs.
                    const options = {
                        signal: inner.signal,
                        requestUserInteraction: (callback) => Promise.resolve().then(callback)
                    };
                    let result;
                    try { result = entry.execute.call(entry.tool, input, options); } catch (e) { return finish(false, e); }
                    announceCall('toolactivated', entry.name);
                    Promise.resolve(result).then((value) => finish(true, value), (error) => finish(false, error));
                });
            }

            function run(name, input, signal) {
                const entry = tools.get(name);
                if (!entry) { return Promise.reject(new DOMException('No tool named ' + name, 'NotFoundError')); }
                if (signal && signal.aborted) { return Promise.reject(signal.reason); }
                return invoke(entry, input === undefined || input === null ? {} : input, signal);
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

            const frameAt = (steps) => {
                try {
                    let w = window.top;
                    for (const i of steps) { w = w.frames[i]; }
                    return w || null;
                } catch (e) { return null; }
            };

            // A tool another document of this page registered, as `getTools()` hands it out.
            const foreign = (t) => {
                const tool = { name: t.name, title: t.title || '', description: t.description, origin: t.origin, window: frameAt(t.path || []) };
                let page = {};
                try { page = parse(t.page || '{}'); } catch (e) {}
                if (page.inputSchema !== undefined) { tool.inputSchema = page.inputSchema; }
                if (page.annotations !== undefined) { tool.annotations = page.annotations; }
                Object.defineProperty(tool, TARGET, { value: t.doc });
                return tool;
            };

            // A call to another document's tool, through six. The caller's abort rejects at once and
            // is passed on to the tool's own signal.
            const elsewhere = (tool, target, args, signal) => new Promise((resolve, reject) => {
                const call = Math.random().toString(36).slice(2) + Date.now().toString(36);
                let settled = false;
                const onAbort = () => {
                    if (settled) { return; }
                    settled = true;
                    reject(signal.reason);
                    post({ kind: 'cancel', call, reason: say(signal.reason) });
                };
                if (signal) { signal.addEventListener('abort', onAbort, { once: true }); }
                const answer = ask({
                    kind: 'execute', call, target: target === undefined ? null : target,
                    name: String(tool.name), origin: String(tool.origin), input: stringify(args)
                });
                const fail = (name, message) => { if (!settled) { settled = true; reject(new DOMException(message, name)); } };
                if (!answer) { return fail('UnknownError', 'No tool named ' + tool.name); }
                answer.then((reply) => {
                    if (signal) { signal.removeEventListener('abort', onAbort); }
                    if (reply && reply.ok) {
                        if (!settled) { settled = true; resolve(reply.value); }
                    } else {
                        fail((reply && reply.error) || 'UnknownError', (reply && reply.message) || 'the call failed');
                    }
                }, (error) => fail('UnknownError', say(error)));
            });

            const constructing = {};
            let token = null;

            class ModelContext extends EventTarget {
                #branded = true;

                constructor() {
                    if (token !== constructing) { throw new TypeError('Illegal constructor'); }
                    super();
                }

                // WebIDL's brand check: an operation called on anything but a ModelContext rejects,
                // an attribute read that way throws.
                static #is(target) { return target !== null && typeof target === 'object' && #branded in target; }
                static #illegal() { return new TypeError('Illegal invocation'); }

                registerTool(tool, options = undefined) {
                    if (!ModelContext.#is(this)) { return Promise.reject(ModelContext.#illegal()); }
                    if (detached()) { return gone(); }
                    const refused = (error) => withUnregister(Promise.reject(error), () => {});
                    let entry;
                    try { entry = validate(tool); } catch (error) { return refused(error); }
                    const signal = options && options.signal;
                    if (signal && signal.aborted) { return refused(signal.reason); }
                    const exposedTo = options && options.exposedTo;
                    entry.exposedTo = [];
                    if (exposedTo !== undefined && exposedTo !== null) {
                        let origins;
                        try { origins = Array.from(exposedTo, String); } catch (error) { return refused(error); }
                        if (!origins.every(trustworthy)) {
                            return refused(new DOMException('exposedTo takes potentially trustworthy origins only', 'SecurityError'));
                        }
                        entry.exposedTo = origins;
                    }
                    if (tools.has(entry.name)) {
                        return refused(new DOMException('A tool named ' + entry.name + ' is already registered', 'InvalidStateError'));
                    }
                    tools.set(entry.name, entry);
                    const answer = announce(entry);
                    changed(this);
                    const unregister = () => remove(this, entry);
                    const done = new Promise((resolve, reject) => {
                        if (signal) {
                            signal.addEventListener('abort', () => { unregister(); reject(signal.reason); }, { once: true });
                        }
                        if (!answer) { queueMicrotask(resolve); return; }
                        answer.then((reply) => {
                            if (!reply || !reply.error) { return resolve(); }
                            if (tools.get(entry.name) === entry) { tools.delete(entry.name); }
                            reject(new DOMException(reply.message || reply.error, reply.error));
                        }, () => resolve());
                    });
                    return withUnregister(done, unregister);
                }

                getTools(options = undefined) {
                    if (!ModelContext.#is(this)) { return Promise.reject(ModelContext.#illegal()); }
                    if (detached()) { return gone(); }
                    let from = [];
                    if (options && options.fromOrigins !== undefined && options.fromOrigins !== null) {
                        try { from = Array.from(options.fromOrigins, String); } catch (error) { return Promise.reject(error); }
                        if (!from.every(trustworthy)) {
                            return Promise.reject(new DOMException('fromOrigins takes potentially trustworthy origins only', 'SecurityError'));
                        }
                    }
                    const sorted = (list) => list.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
                    const own = Array.from(tools.values(), registered);
                    const answer = brokered ? ask({ kind: 'getTools', fromOrigins: from.map((o) => new URL(o).origin) }) : null;
                    if (!answer) { return Promise.resolve(sorted(own)); }
                    return answer.then((reply) => {
                        if (reply && reply.error) { throw new DOMException(reply.message || reply.error, reply.error); }
                        return sorted(own.concat(((reply && reply.tools) || []).map(foreign)));
                    });
                }

                executeTool(tool, input = undefined, options = undefined) {
                    if (!ModelContext.#is(this)) { return Promise.reject(ModelContext.#illegal()); }
                    if (detached()) { return gone(); }
                    if (!tool || typeof tool !== 'object' || typeof tool.name !== 'string') {
                        return Promise.reject(new TypeError('executeTool: pass a tool from getTools()'));
                    }
                    if (tool.origin === undefined) {
                        return Promise.reject(new TypeError("executeTool: the tool's origin is required"));
                    }
                    let serialized = 'null';
                    try { serialized = new URL(String(tool.origin)).origin; } catch (e) {}
                    if (serialized === 'null') {
                        return Promise.reject(new DOMException('executeTool: the tool has an opaque origin', 'NotSupportedError'));
                    }
                    const signal = options && options.signal;
                    if (signal && signal.aborted) { return Promise.reject(signal.reason); }
                    let args;
                    try { args = argumentsOf(input); } catch (error) {
                        return Promise.reject(error instanceof TypeError ? error : new TypeError(say(error)));
                    }
                    try {
                        if (tool.window && tool.window.closed) {
                            return Promise.reject(new DOMException('the tool\'s document is not active', 'InvalidStateError'));
                        }
                    } catch (e) {}
                    const target = tool[TARGET];
                    const entry = target === undefined || target === doc ? tools.get(tool.name) : undefined;
                    if (!entry || (target === undefined && tool.origin !== String(self.origin))) {
                        if (!brokered) { return Promise.reject(new DOMException('No tool named ' + tool.name, 'UnknownError')); }
                        return elsewhere(tool, target, args, signal);
                    }
                    return invoke(entry, args, signal).catch((error) => {
                        if (signal && signal.aborted && error === signal.reason) { throw error; }
                        throw new DOMException(say(error), 'UnknownError');
                    });
                }

                get ontoolchange() {
                    if (!ModelContext.#is(this)) { throw ModelContext.#illegal(); }
                    return handlers.toolchange;
                }
                set ontoolchange(handler) { this.#handle('toolchange', handler); }
                get ontoolactivated() {
                    if (!ModelContext.#is(this)) { throw ModelContext.#illegal(); }
                    return handlers.toolactivated;
                }
                set ontoolactivated(handler) { this.#handle('toolactivated', handler); }

                #handle(type, handler) {
                    if (handlers[type]) { this.removeEventListener(type, handlers[type]); }
                    handlers[type] = typeof handler === 'function' ? handler : null;
                    if (handlers[type]) { this.addEventListener(type, handlers[type]); }
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

            // Operations and attributes are enumerable on an IDL prototype; a class's are not.
            for (const prototype of [ModelContext.prototype, ToolActivatedEvent.prototype]) {
                for (const key of Object.getOwnPropertyNames(prototype)) {
                    if (key === 'constructor') { continue; }
                    Object.defineProperty(prototype, key, Object.assign(Object.getOwnPropertyDescriptor(prototype, key), { enumerable: true }));
                }
            }
            Object.defineProperty(ModelContext.prototype, Symbol.toStringTag, { value: 'ModelContext', configurable: true });
            Object.defineProperty(ToolActivatedEvent.prototype, Symbol.toStringTag, { value: 'ToolActivatedEvent', configurable: true });

            token = constructing;
            const context = new ModelContext();
            token = null;
            try {
                Object.defineProperty(window, 'ModelContext', { value: ModelContext, configurable: true, writable: true });
                Object.defineProperty(window, 'ToolActivatedEvent', { value: ToolActivatedEvent, configurable: true, writable: true });
            } catch (e) {}
            // `[SameObject] readonly attribute ModelContext modelContext` on Document. The first
            // trial's `navigator.modelContext` is not in the IDL and stays a plain property.
            try {
                const getter = Object.getOwnPropertyDescriptor({
                    get modelContext() {
                        if (!(this instanceof Document)) { throw new TypeError('Illegal invocation'); }
                        return this === document ? context : null;
                    }
                }, 'modelContext').get;
                Object.defineProperty(Document.prototype, 'modelContext', { get: getter, configurable: true, enumerable: true });
                Object.defineProperty(navigator, 'modelContext', { value: context, configurable: true, enumerable: true });
            } catch (e) {}

            Object.defineProperty(window, '\#(bridgeKey)', {
                configurable: true,
                value: Object.freeze({
                    doc,
                    toolchange() { changed(context); return true; },
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
            window.addEventListener('pagehide', () => { post({ kind: 'gone' }); });
            window.addEventListener('pageshow', (event) => {
                if (!event.persisted) { return; }
                post({ kind: 'document', url: String(location.href), path });
                for (const entry of tools.values()) { announce(entry); }
            });
        })();
        """#
    }
}
