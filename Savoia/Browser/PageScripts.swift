import WebKit

/// Everything Savoia runs inside a page runs here: a `WKContentWorld` of its own. The DOM is shared, the
/// JavaScript is not — the page cannot redefine `querySelectorAll` or the `innerText` getter to feed
/// the extractor (and the model behind it) text a person never sees, and it cannot see or touch our
/// globals. This is the reader-mode arrangement of Firefox and Safari: the browser's script reads the
/// page from a privileged context, never as a guest of the page's own scripts. The one deliberate
/// exception is `evaluate_javascript`, which is *for* the page's world.
extension WKContentWorld {
    static let savoia = WKContentWorld.world(name: "savoia")
}

extension WebPage {
    /// `callJavaScript` in Savoia's world. A plain function body, no `await` (the API runs a function, not
    /// an async one).
    func savoia(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await callJavaScript(functionBody, arguments: arguments, contentWorld: .savoia)
    }
}

#if os(macOS)
extension BrowserTab {
    /// A function body run in the page with no user gesture attached. `callJavaScript` is one to
    /// WebKit: the page may then open windows, play sound and read the clipboard as if a person had
    /// clicked (docs/page-scripts.md). Needs the tab's view: a page no pane has shown has none to
    /// ask, and gets the ordinary call.
    func callWithoutGesture(_ functionBody: String, arguments: [String: Any] = [:],
                            in world: WKContentWorld? = nil) async throws -> Any? {
        resumeIfNeeded()
        let world = world ?? .savoia
        guard let view = WebViewResponder.shared.webView(for: id),
              view.responds(to: #selector(GesturelessCalls.call(_:arguments:in:in:withUserGesture:completionHandler:)))
        else { return try await page.callJavaScript(functionBody, arguments: arguments, contentWorld: world) }
        let answer: UncheckedBox<Result<Any?, any Error>> = await withCheckedContinuation { continuation in
            unsafeBitCast(view, to: GesturelessCalls.self).call(
                functionBody, arguments: arguments, in: nil, in: world, withUserGesture: false
            ) { value, error in
                continuation.resume(returning: UncheckedBox(value: error.map { .failure($0) } ?? .success(value)))
            }
        }
        return try answer.value.get()
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

@objc private protocol GesturelessCalls {
    @objc(_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:)
    func call(_ functionBody: String, arguments: [String: Any]?, in frame: WKFrameInfo?, in world: WKContentWorld,
              withUserGesture: Bool, completionHandler: (@MainActor (Any?, (any Error)?) -> Void)?)
}
#endif
