#if os(macOS)
import AppKit
import WebKit

/// Which tab's page has the keyboard, as distinct from which tab is selected: AppKit's first
/// responder stays on the web view it was last given, and with two tabs side by side typing would
/// land in the half that is not highlighted. A tab leaves its view here as it builds one.
@MainActor
final class WebViewResponder {
    static let shared = WebViewResponder()

    private var views: [UUID: WeakView] = [:]

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView?) { self.view = view }
    }

    func register(_ view: WKWebView, for tabID: UUID) {
        views[tabID] = WeakView(view)
    }

    func forget(_ tabID: UUID) {
        views[tabID] = nil
    }

    /// Hands the keyboard to a window's page, or — for a window that has no page to hand it to — takes
    /// it off whatever had it.
    ///
    /// **Not while something is being typed into.** The one first responder that outranks a page is a
    /// text field: `⌘L` and the `⌘E` line are reached by keystroke and left by keystroke, and a row
    /// that walked into the page under them would eat the next thing typed. The same test the key
    /// router uses (`KeyContext`), for the same reason.
    func focus(_ tabID: UUID?) {
        views = views.filter { $0.value.view != nil } // windows that have closed since
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        guard !(window.firstResponder is NSText) else { return }
        guard let tabID, let view = views[tabID]?.view, view.window === window else {
            // Nothing to give it to. The keys go to the window itself rather than staying with a page
            // the row is no longer looking at — a window that answers keys it is not the subject of
            // is worse than one that answers none.
            if window.firstResponder is WKWebView { window.makeFirstResponder(nil) }
            return
        }
        guard window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    /// Which window's page holds the keyboard, if a page does. The question the split made worth
    /// asking out loud: the row's focus and this can disagree, and `KeySelfTest` prints both.
    func owner(of responder: NSResponder?) -> UUID? {
        guard let view = responder as? NSView else { return nil }
        return views.first { $0.value.view === view }?.key
    }
}
#endif
