import Foundation

/// What a page reports about itself when devtools capture is on.
nonisolated struct ConsoleMessage: Identifiable, Sendable, Hashable {
    var id = UUID()
    /// `log`, `info`, `warn`, `error`, `debug` — plus `error` for uncaught exceptions and rejections.
    var level: String
    var text: String
    var at: Date
    var url: String
}

/// A request the page made. Not the network layer's word — the page's; see `PageInstrumentation`.
nonisolated struct NetworkEntry: Identifiable, Sendable, Hashable {
    var id = UUID()
    var url: String
    var method: String
    /// Nil when the request never got a response (blocked, offline, CORS).
    var status: Int?
    /// `fetch`, `xhr`, `script`, `img`, `css`, `link`, `beacon`… — from the page or from resource timing.
    var kind: String
    var milliseconds: Int
    var bytes: Int?
    var error: String?
    var at: Date

    /// A `no-cors` response is opaque and reports status 0 — that is not a failure, it is what the
    /// page asked for. A failure is an error, or a status the server meant as one.
    var isFailed: Bool { error != nil || (status ?? 0) >= 400 }

    /// What to show for the status: the number, `opaque` for a cross-origin response the page cannot
    /// read, or nothing when the request was only seen through resource timing.
    var statusText: String {
        if let error { return "failed: \(error)" }
        guard let status else { return "—" }
        return status == 0 ? "opaque" : String(status)
    }

    var sizeText: String {
        guard let bytes else { return "" }
        return bytes >= 1024 ? " \(bytes / 1024) KB" : " \(bytes) B"
    }
}

/// The JavaScript six runs inside a page to report its console and its requests.
///
/// **This one runs in the page's own world, and that is a deliberate exception.** Everything else six
/// injects lives in a `WKContentWorld` of its own precisely so a page cannot see it
/// ([architecture.md](../../docs/architecture.md#page-side-scripts)) — but `console.log` and `fetch`
/// are the page's own globals, and wrapping them anywhere else would wrap nothing. WebKit exposes no
/// API for reading a page's console or its resource loads, and the Web Inspector protocol is not
/// reachable from the app that hosts the page, so a page-world hook is the only way to answer "what
/// did this page log, and what did it request".
///
/// The consequences are stated rather than hidden: the page can see the wrappers, can replace them,
/// and can post to the message handler itself. That is why capture is **off by default**, why the
/// handler's name is different on every launch, and why what comes back is described as the page's
/// account of itself rather than the browser's.
enum PageInstrumentation {
    /// Different every launch, so a page cannot count on finding it.
    static let handlerName = "six" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()

    static var source: String {
        """
        (function () {
            if (window.__sixDevTools) { return; }
            window.__sixDevTools = true;
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!handler) { return; }
            const post = (body) => { try { handler.postMessage(body); } catch (e) {} };
            const say = (value) => {
                if (typeof value === 'string') { return value; }
                if (value instanceof Error) { return value.name + ': ' + value.message; }
                try { return JSON.stringify(value); } catch (e) { return String(value); }
            };

            for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
                const original = console[level] ? console[level].bind(console) : null;
                console[level] = function (...args) {
                    post({ kind: 'console', level, text: args.map(say).join(' ').slice(0, 4000) });
                    if (original) { original(...args); }
                };
            }

            window.addEventListener('error', (event) => {
                const where = event.filename ? ' (' + event.filename + ':' + (event.lineno || 0) + ')' : '';
                post({ kind: 'console', level: 'error', text: (event.message || 'Script error') + where });
            });
            window.addEventListener('unhandledrejection', (event) => {
                post({ kind: 'console', level: 'error', text: 'Unhandled promise rejection: ' + say(event.reason) });
            });

            const nativeFetch = window.fetch;
            if (nativeFetch) {
                window.fetch = function (input, init) {
                    const started = performance.now();
                    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
                    const method = (init && init.method) || (input && input.method) || 'GET';
                    return nativeFetch.apply(this, arguments).then((response) => {
                        post({ kind: 'network', type: 'fetch', url, method, status: response.status,
                               ms: Math.round(performance.now() - started) });
                        return response;
                    }, (error) => {
                        post({ kind: 'network', type: 'fetch', url, method, error: say(error),
                               ms: Math.round(performance.now() - started) });
                        throw error;
                    });
                };
            }

            const open = XMLHttpRequest.prototype.open;
            const send = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function (method, url) {
                this.__sixMethod = method; this.__sixURL = url;
                return open.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function () {
                const started = performance.now();
                const report = (extra) => post(Object.assign({
                    kind: 'network', type: 'xhr', url: String(this.__sixURL || ''), method: this.__sixMethod || 'GET',
                    ms: Math.round(performance.now() - started)
                }, extra));
                this.addEventListener('load', () => report({ status: this.status }));
                this.addEventListener('error', () => report({ error: 'Network error' }));
                this.addEventListener('abort', () => report({ error: 'Aborted' }));
                return send.apply(this, arguments);
            };

            // Everything the page did not ask for by hand — scripts, images, stylesheets, beacons.
            // `fetch` and `xmlhttprequest` are skipped: they are already reported above, with a status.
            try {
                new PerformanceObserver((list) => {
                    for (const entry of list.getEntries()) {
                        if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') { continue; }
                        post({ kind: 'network', type: entry.initiatorType || 'other', url: entry.name, method: 'GET',
                               ms: Math.round(entry.duration), bytes: entry.transferSize });
                    }
                }).observe({ type: 'resource', buffered: true });
            } catch (e) {}
        })();
        """
    }
}
