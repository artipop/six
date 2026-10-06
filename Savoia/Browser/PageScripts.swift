import WebKit
#if os(macOS)
import AppKit
#endif

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
    /// clicked (docs/page-scripts.md). Needs the tab's view: a page on screen waits for its pane to
    /// find it, and a page no pane shows has none to ask and gets the ordinary call.
    func callWithoutGesture(_ functionBody: String, arguments: [String: Any] = [:],
                            in world: WKContentWorld? = nil, frame: WKFrameInfo? = nil) async throws -> Any? {
        resumeIfNeeded()
        let world = world ?? .savoia
        var view = WebViewResponder.shared.webView(for: id)
        if view == nil, cache?.isOnScreen(id) == true { view = await WebViewResponder.shared.awaitedWebView(for: id) }
        guard let view, view.canCallWithoutGesture
        else { return try await page.callJavaScript(functionBody, arguments: arguments, contentWorld: world) }
        return try await view.callWithoutGesture(functionBody, arguments: arguments, in: world, frame: frame)
    }

    /// A mouse click at a point of the page's viewport, in CSS pixels, as an event handed to the web
    /// view: trusted, and a user gesture. False when the page has no view on screen to hand it to.
    @discardableResult
    func click(atViewport point: CGPoint) -> Bool {
        WebViewResponder.shared.webView(for: id)?.click(atViewport: point) ?? false
    }
}

extension WKWebView {
    var canCallWithoutGesture: Bool {
        responds(to: #selector(GesturelessCalls.call(_:arguments:in:in:withUserGesture:completionHandler:)))
    }

    func callWithoutGesture(_ functionBody: String, arguments: [String: Any] = [:],
                            in world: WKContentWorld, frame: WKFrameInfo? = nil) async throws -> Any? {
        let answer: UncheckedBox<Result<Any?, any Error>> = await withCheckedContinuation { continuation in
            unsafeBitCast(self, to: GesturelessCalls.self).call(
                functionBody, arguments: arguments, in: frame, in: world, withUserGesture: false
            ) { value, error in
                continuation.resume(returning: UncheckedBox(value: error.map { .failure($0) } ?? .success(value)))
            }
        }
        return try answer.value.get()
    }

    /// One mouse event at a point of the viewport, in CSS pixels. False when the view is in no window.
    @discardableResult
    func mouse(_ type: NSEvent.EventType, atViewport point: CGPoint) -> Bool {
        guard let window else { return false }
        let inView = CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: convert(inView, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: mouseMoved(with: event)
        }
        return true
    }

    @discardableResult
    func click(atViewport point: CGPoint) -> Bool {
        mouse(.leftMouseDown, atViewport: point) && mouse(.leftMouseUp, atViewport: point)
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
