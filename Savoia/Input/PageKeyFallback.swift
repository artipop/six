#if os(macOS)
import AppKit
import ObjectiveC
import WebKit

/// A page with nothing to do with Return, Space, Esc or a navigation key stays quiet.
///
/// WebKit first lets the DOM, editor and scrolling handle a key. When none does, it resends
/// the event through AppKit and calls `super.keyDown`. The host window still gets to answer
/// Return with its default button; only what it passes along is quieted. Standing before
/// the window would silence that button along with the alert.
@MainActor
final class PageKeyFallback: NSResponder {
    private static var association: UInt8 = 0
    /// Space and the page keys are numbers because `KeyCode` holds only what the binding table names.
    private static let quieted: Set<UInt16> = Set([KeyCode.returnKey, .keypadEnter, .escape, .leftArrow,
        .rightArrow, .upArrow, .downArrow, .home, .end].map(\.rawValue)).union([49, 116, 121])
    private weak var window: NSWindow?

    static func install(on webView: WKWebView) {
        guard let window = webView.window, !window.isSheet, window.parent == nil else { return }
        let fallback: PageKeyFallback
        if let existing = objc_getAssociatedObject(window, &association) as? PageKeyFallback {
            fallback = existing
        } else {
            fallback = PageKeyFallback()
            fallback.window = window
            objc_setAssociatedObject(window, &association, fallback, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // SwiftUI may rebuild the responder chain. Rejoin it, but never insert a responder
        // already farther along it: that would make a cycle when another responder was added.
        var next = window.nextResponder
        while let responder = next {
            if responder === fallback { return }
            next = responder.nextResponder
        }
        fallback.nextResponder = window.nextResponder
        window.nextResponder = fallback
    }

    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection(.heldByHand)
        if let window, event.window === window, window.firstResponder is WKWebView,
           held.isEmpty || held == .shift, Self.quieted.contains(event.keyCode) {
            return
        }
        super.keyDown(with: event)
    }
}
#endif
