import WebKit

/// Everything six runs inside a page runs here: a `WKContentWorld` of its own. The DOM is shared, the
/// JavaScript is not — the page cannot redefine `querySelectorAll` or the `innerText` getter to feed
/// the extractor (and the model behind it) text a person never sees, and it cannot see or touch our
/// globals. This is the reader-mode arrangement of Firefox and Safari: the browser's script reads the
/// page from a privileged context, never as a guest of the page's own scripts. The one deliberate
/// exception is `evaluate_javascript`, which is *for* the page's world.
extension WKContentWorld {
    nonisolated(unsafe) static let six = WKContentWorld.world(name: "six")
}

extension WebPage {
    /// `callJavaScript` in six's world. A plain function body, no `await` (the API runs a function, not
    /// an async one).
    func six(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await callJavaScript(functionBody, arguments: arguments, contentWorld: .six)
    }
}
