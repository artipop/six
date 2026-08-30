import Foundation
import WebKit

/// The two URLs behind a running app, and the handler that serves them.
///
/// An app is not loaded with `load(html:)`. It is *served* — from a scheme of six's own, with real
/// response headers — because the extension's security model is a `Content-Security-Policy` the host
/// constructs from the server's metadata, and a header is the only place a policy can be stated
/// where the document cannot argue with it.
///
/// There are two documents, on two schemes, and therefore two origins:
///
/// ```
/// mcp-app://<app>/           the shell — six's own, six lines of HTML and an iframe
///   └── mcp-app-content://<app>/   the app — the server's HTML, under the server's CSP
/// ```
///
/// The shell is what gives the app a `window.parent` that is genuinely another window: the SDK's
/// transport posts to `window.parent` and validates `event.source` against it, so a single top-level
/// document would have the app talking to itself and six unable to tell its own messages from the
/// app's. The shell also keeps six's relay script out of the untrusted document entirely — nothing
/// is ever injected into the app's own frame.
///
/// This is the spec's sandbox-proxy arrangement, arrived at from the other side. A *web* host must
/// build it out of two iframes because it has only one origin to work with; six has as many origins
/// as it cares to name, and a whole web content process per window besides.
nonisolated enum MCPAppScheme {
    /// The shell.
    static let shell = "mcp-app"
    /// The app's own document.
    static let content = "mcp-app-content"

    static func shellURL(host: String) -> URL { URL(string: "\(shell)://\(host)/")! }
    static func contentURL(host: String) -> URL { URL(string: "\(content)://\(host)/")! }

    /// The host part of both URLs — the app's identity, and the origin it keeps between runs.
    ///
    /// `_meta.ui.domain` when the server asked for one (an app that needs a stable origin for an
    /// OAuth callback), otherwise a name derived from the `ui://` URI, so the same template always
    /// lands on the same origin and what it stored is still there next time.
    static func host(for resource: MCPUIResource) -> String {
        if let domain = resource.domain, !domain.isEmpty, isPlausibleHost(domain) { return domain }
        let slug = resource.uri
            .replacingOccurrences(of: "ui://", with: "")
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(slug).split(separator: "-").joined(separator: "-")
    }

    private static func isPlausibleHost(_ domain: String) -> Bool {
        !domain.contains("/") && !domain.contains(":") && !domain.contains(" ")
            && domain.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// Serves one app's two documents. Immutable once built: the HTML and the policy are decided when
/// the app opens, and a running app cannot talk the handler into serving it something else.
nonisolated final class MCPAppSchemeHandler: URLSchemeHandler, Sendable {
    private let host: String
    private let shell: Data
    private let content: Data
    private let contentPolicy: String

    init(resource: MCPUIResource) {
        host = MCPAppScheme.host(for: resource)
        contentPolicy = resource.csp.header
        content = Data(resource.html.utf8)
        shell = Data(Self.shellHTML(host: host, permissions: resource.permissions).utf8)
    }

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        let scheme = request.url?.scheme?.lowercased()
        let isShell = scheme == MCPAppScheme.shell
        let body = isShell ? shell : content
        // The shell's own policy is six's to write, and it is as small as a policy gets: no
        // network, no scripts of the document's own (six's relay is a user script, which CSP does
        // not govern), and exactly one frame — the app's.
        let policy = isShell
            ? "default-src 'none'; style-src 'unsafe-inline'; frame-src \(MCPAppScheme.content):; base-uri 'none'"
            : contentPolicy
        let url = request.url ?? MCPAppScheme.shellURL(host: host)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": policy,
            "Content-Length": String(body.count),
            // An app is a document, never a download, and never anyone's frame but the shell's.
            "X-Content-Type-Options": "nosniff",
        ])
        return AsyncThrowingStream { continuation in
            if let response {
                continuation.yield(.response(response))
                continuation.yield(.data(body))
                continuation.finish()
            } else {
                continuation.finish(throwing: URLError(.badServerResponse))
            }
        }
    }

    /// The shell: a full-bleed frame and nothing else. `color-scheme: inherit` and the transparent
    /// background are what let an app that draws nothing of its own take six's own backdrop.
    private static func shellHTML(host: String, permissions: MCPUIResource.Permissions) -> String {
        let allow = [
            permissions.camera ? "camera" : nil,
            permissions.microphone ? "microphone" : nil,
            permissions.geolocation ? "geolocation" : nil,
            permissions.clipboardWrite ? "clipboard-write" : nil,
        ].compactMap { $0 }.joined(separator: "; ")
        let allowAttribute = allow.isEmpty ? "" : " allow=\"\(allow)\""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(host)</title>
        <style>
          html, body { margin: 0; height: 100%; background: transparent; }
          iframe { display: block; width: 100%; height: 100%; border: 0; background: transparent;
                   color-scheme: inherit; }
        </style></head>
        <body><iframe id="\(MCPAppBridge.frameID)" src="\(MCPAppScheme.contentURL(host: host).absoluteString)"
              sandbox="allow-scripts allow-same-origin allow-forms allow-modals"\(allowAttribute)></iframe></body>
        </html>
        """
    }
}
