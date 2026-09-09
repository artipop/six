#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Which window's page has the keyboard, as distinct from which window the rail has the focus on.
///
/// The two used to be able to disagree, and a split is where that stopped being invisible. `⌥→`
/// moves the rail's focus: the accent border steps to the next window and everything keyed off the
/// selection — the address field, `⌘W`, the assistant — follows it. What did not follow was AppKit's
/// **first responder**, which stayed on the `WKWebView` it was last given by a click. So the arrow
/// keys went on scrolling the window you had just walked away from, and text went on arriving in its
/// text field. On a rail that was hard to see, because the window you left is off the edge of the
/// screen a moment later; two halves of one column are both in front of you, and one of them is
/// visibly highlighted while your typing lands in the other.
///
/// SwiftUI has no handle on the `WKWebView` inside a `WebView`, and there is no route from a
/// `WebPage` to it either, so each pane leaves one here: `WebViewResponder.Handle` is a zero-size
/// AppKit view mounted beside its own web view, which finds it and registers it under the window's
/// id. `ContentView` asks for the focused one whenever the selection moves.
@MainActor
final class WebViewResponder {
    static let shared = WebViewResponder()

    private var views: [UUID: WeakView] = [:]

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView?) { self.view = view }
    }

    /// Registers the web view a handle is standing on, if it can be found.
    ///
    /// **By frame, and not by walking the view tree.** Climbing from the handle to the nearest
    /// ancestor holding exactly one web view is the obvious way and it does not work: SwiftUI mounts
    /// a `.background` in a layer of its own, so the first ancestor with any web view under it is
    /// usually the one that has *all* of them, and the answer comes back empty — measured, with the
    /// keyboard handed to the window instead of to a page. A pane's handle is given the pane's own
    /// size, so the web view it belongs to is the one whose middle lands inside it. That holds
    /// whatever SwiftUI does with the hierarchy.
    func claim(beside handle: NSView, for tabID: UUID) {
        guard let window = handle.window, let root = window.contentView else { return }
        let mine = handle.convert(handle.bounds, to: nil)
        guard mine.width > 1, mine.height > 1 else { return }
        var found: NSView?
        var stack = [root]
        while let here = stack.popLast() {
            if here is WKWebView {
                let theirs = here.convert(here.bounds, to: nil)
                if mine.contains(CGPoint(x: theirs.midX, y: theirs.midY)) { found = here }
                continue // a web view's own subviews are WebKit's business
            }
            stack.append(contentsOf: here.subviews)
        }
        guard let found else { return }
        views[tabID] = WeakView(found)
        Log.debug(.keys, "the keyboard can reach \(tabID.uuidString.prefix(8)) at \(Int(mine.width))pt")
    }

    func forget(_ tabID: UUID) {
        views[tabID] = nil
    }

    /// Hands the keyboard to a window's page, or — for a window that has no page to hand it to — takes
    /// it off whatever had it.
    ///
    /// **Not while something is being typed into.** The one first responder that outranks a page is a
    /// text field: `⌘L` and the `⌘K` line are reached by keystroke and left by keystroke, and a rail
    /// that walked into the page under them would eat the next thing typed. The same test the key
    /// router uses (`KeyContext`), for the same reason.
    func focus(_ tabID: UUID?) {
        views = views.filter { $0.value.view != nil } // windows that have closed since
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        guard !(window.firstResponder is NSText) else { return }
        guard let tabID, let view = views[tabID]?.view, view.window === window else {
            // Nothing to give it to. The keys go to the window itself rather than staying with a page
            // the rail is no longer looking at — a window that answers keys it is not the subject of
            // is worse than one that answers none.
            if window.firstResponder is WKWebView { window.makeFirstResponder(nil) }
            return
        }
        guard window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    /// Which window's page holds the keyboard, if a page does. The question the split made worth
    /// asking out loud: the rail's focus and this can disagree, and `KeySelfTest` prints both.
    func owner(of responder: NSResponder?) -> UUID? {
        guard let view = responder as? NSView else { return nil }
        return views.first { $0.value.view === view }?.key
    }

    /// Mounted inside a pane, beside its web view, so the pane can be found again from the outside.
    struct Handle: NSViewRepresentable {
        let tabID: UUID

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            view.setAccessibilityElement(false)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            // Walked on every update rather than once: SwiftUI is free to rebuild the web view under
            // us — a page discarded and built again is a new `WKWebView` (`BrowserTab.generation`) —
            // and a handle pointing at the old one is a handle that gives the keyboard to nothing.
            //
            // Once now and once in a moment, because an update can arrive before the web view beside
            // it is in the window: the first attempt then finds nothing, and without the second the
            // pane would have no handle for the rest of its life.
            let tabID = self.tabID
            Task { @MainActor in
                WebViewResponder.shared.claim(beside: view, for: tabID)
                try? await Task.sleep(for: .milliseconds(150))
                WebViewResponder.shared.claim(beside: view, for: tabID)
            }
        }
    }
}
#endif
