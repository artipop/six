#if os(macOS)
import ObjectiveC
import WebKit

/// WebKit's own inspector on a tab: `_WKInspector`, SPI behind `responds(to:)`.
enum WebInspector {
    private static let extrasSetter = Selector(("_setDeveloperExtrasEnabled:"))
    private static let getter = Selector(("_inspector"))
    /// A page narrower than this share of its window gets the inspector in a window of its own.
    private static let dockedShare = 0.6
    private static let delegateSetter = NSSelectorFromString("setDelegate:")
    private static var placementKey: UInt8 = 0

    static var isAvailable: Bool {
        WKWebView.instancesRespond(to: getter) && WKPreferences.instancesRespond(to: extrasSetter)
    }

    /// Without it `show` returns and nothing opens. Set before the view is made.
    static func allow(in configuration: WKWebViewConfiguration) {
        guard configuration.preferences.responds(to: extrasSetter) else { return }
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    static func isOpen(on page: WKWebView) -> Bool {
        inspector(of: page)?.value(forKey: "isVisible") as? Bool ?? false
    }

    /// Docked under the page rather than in a window of its own.
    static func isDocked(on page: WKWebView) -> Bool {
        guard isOpen(on: page), let frontend = frontend(of: page) else { return false }
        return frontend.window != nil && frontend.window === page.window
    }

    static func toggle(on page: WKWebView) {
        isOpen(on: page) ? close(on: page) : open(on: page)
    }

    static func open(on page: WKWebView) {
        guard let inspector = inspector(of: page) else { return }
        let window = page.window?.contentView?.bounds.width ?? 0
        let isWide = window > 0 && page.bounds.width >= window * dockedShare
        // The frontend puts itself where it last stood as it loads, so the choice is made after that.
        let placement = Placement { [weak inspector] in
            if let inspector { send(isWide ? "attach" : "detach", to: inspector) }
        }
        objc_setAssociatedObject(page, &placementKey, placement, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if inspector.responds(to: delegateSetter) { inspector.perform(delegateSetter, with: placement) }
        send("show", to: inspector)
    }

    static func close(on page: WKWebView) {
        guard isOpen(on: page), let inspector = inspector(of: page) else { return }
        send("close", to: inspector)
    }

    /// ⌘W in the inspector's own window is that window's, not the tab's.
    static func closeWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.className == "_WKInspectorWindow" else { return false }
        window.performClose(nil)
        return true
    }

    static func frontend(of page: WKWebView) -> WKWebView? {
        inspector(of: page)?.value(forKey: "inspectorWebView") as? WKWebView
    }

    private static func inspector(of page: WKWebView) -> NSObject? {
        guard page.responds(to: getter) else { return nil }
        return page.perform(getter)?.takeUnretainedValue() as? NSObject
    }

    private static func send(_ name: String, to inspector: NSObject) {
        let selector = Selector(name)
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    /// `_WKInspectorDelegate`, which the inspector holds weakly.
    private final class Placement: NSObject {
        let place: () -> Void

        init(place: @escaping () -> Void) {
            self.place = place
        }

        @objc(inspectorFrontendLoaded:) func frontendLoaded(_ inspector: NSObject) {
            place()
        }
    }
}
#endif
