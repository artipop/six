#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Which tab's page has the keyboard, as distinct from which tab is selected. Everything keyed off
/// the selection follows it — the address field, `⌘W`, the assistant — but AppKit's first responder
/// stays on the `WKWebView` it was last given, and with two tabs side by side your typing would land
/// in the half that is not highlighted.
///
/// SwiftUI has no handle on the `WKWebView` inside a `WebView`, and there is no route from a
/// `WebPage` to it either, so each pane leaves one here: `WebViewResponder.Handle` is a zero-size
/// AppKit view mounted beside its own web view, which finds it and registers it under the window's
/// id. `ContentView` asks for the focused one whenever the selection moves.
@MainActor
final class WebViewResponder {
    static let shared = WebViewResponder()

    private var views: [UUID: WeakView] = [:]

    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

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
        release(tabID)
        Log.debug(.keys, "the keyboard can reach \(tabID.uuidString.prefix(8)) at \(Int(mine.width))pt")
        if let webView = found as? WKWebView {
            PageKeyFallback.install(on: webView)
            onWebViewFound(tabID, webView)
        }
    }

    /// Told on every claim, with the live `WKWebView` — the only moment anything outside WebKit gets a
    /// hold of it, since `WebPage` never hands one out. Every claim and not just the first, because a
    /// page discarded and rebuilt is a new view behind the same tab id; each callee tells a view it
    /// has already seen from a fresh one (`DisplayCapture.observe`, `WebPage.allowPictureInPicture`).
    /// A plain callback wired at launch, so this file stays free of the browser's own model.
    var onWebViewFound: (UUID, WKWebView) -> Void = { _, _ in }

    func forget(_ tabID: UUID) {
        views[tabID] = nil
    }

    /// The live `WKWebView` behind a tab — the one door Savoia has to it, since `WebPage` hands none out.
    /// Extensions (`ExtensionTabAdapter.webView(for:)`, `docs/extensions.md`), the screen-sharing mute,
    /// picture-in-picture's question and element fullscreen's hold all come through here; nothing
    /// reflects into `WebPage`'s storage any more. The same reference `focus(_:)` trusts for the
    /// keyboard — matched by frame containment, re-claimed on every layout pass — not a fresh guess.
    /// A page no pane has shown yet answers `nil`.
    func webView(for tabID: UUID) -> WKWebView? {
        views[tabID]?.view as? WKWebView
    }

    /// The same, for a tab whose pane is on its way to the screen: waits for the claim, a second at most.
    func awaitedWebView(for tabID: UUID) async -> WKWebView? {
        if let view = webView(for: tabID) { return view }
        await withCheckedContinuation { continuation in
            waiters[tabID, default: []].append(continuation)
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.release(tabID)
            }
        }
        return webView(for: tabID)
    }

    private func release(_ tabID: UUID) {
        waiters.removeValue(forKey: tabID)?.forEach { $0.resume() }
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
