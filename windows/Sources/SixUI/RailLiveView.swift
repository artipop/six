import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// The one live column: a real `WKView` for the focused tab, created lazily and kept alive rather
/// than rebuilt, so switching back to a tab does not reload it. No live-page budget yet, and no
/// second live column — docs/windows.md.
extension RailWindow {
    /// Resyncing from the model on every repaint, rather than threading a notification through
    /// every mutation that could move focus: the model is the source of truth either way.
    func updateLiveView() {
        guard let hwnd else { return }
        pruneClosedWebViews()

        // The translation banner is a second line of chrome that comes and goes, so the rail's
        // canvas is not a constant. Told here rather than only on `WM_SIZE`, because nothing
        // resizes when a translation starts.
        if topChromeHeight != lastChromeHeight {
            lastChromeHeight = topChromeHeight
            var client = RECT()
            GetClientRect(hwnd, &client)
            _ = model.updateViewport(CGSize(width: Int(client.right),
                                            height: max(0, Int(client.bottom) - Int(topChromeHeight))))
        }

        // The bar follows the rail on every repaint, because a profile switch onto an empty strip is
        // a repaint and nothing else: no focused window means no address field and no page title.
        layoutAddressBar()
        updateWindowTitle()

        let columns = model.columns
        guard let focused = columns.first(where: \.isFocused) else {
            for view in webViews.values { view.setVisible(false) }
            addressBarShownTabID = nil
            return
        }
        syncAddressBarIfNeeded(focusedTabID: focused.id)
        let body = bodyRect(for: focused.frame)

        let webView = webViews[focused.id] ?? makeWebView(for: focused.id, parent: hwnd, frame: body)
        guard let webView else { return }

        // Everything that is not the focused column, including the columns of a profile that is not
        // on screen: `columns` is the active profile's strip alone, so this is what hides the pages
        // of the profile just switched away from.
        for (id, view) in webViews where id != focused.id {
            view.setVisible(false)
        }
        webView.setFrame(body)
        webView.setVisible(true)
        traceActualFrame(of: webView, parent: hwnd, intended: body)
    }

    /// What the focused page currently says it is, on a timer (`RailWindow.pageStateTimer`).
    ///
    /// Three things this front draws are the page's rather than the rail's — the title on the card,
    /// the address in the bar, and whether back and forward can do anything — and WebKit announces
    /// none of them at a moment that is late enough to be true: `didFinishNavigation` fires with the
    /// old title still in place, and pushing onto the back-forward list is not announced at all.
    /// Polling four times a second is what the Mac gets from `WebPage`'s observation for free.
    ///
    /// It repaints only on a change, so an idle window is idle.
    func refreshLivePageState() {
        guard let focused = model.columns.first(where: \.isFocused), let view = webViews[focused.id] else { return }
        var changed = false

        let title = view.title
        if !title.isEmpty, title != focused.title {
            model.setTitle(title, for: focused.id)
            changed = true
        }
        let url = view.url
        if !url.isEmpty, url != model.url(for: focused.id) {
            model.setURL(url, for: focused.id)
            changed = true
        }
        let navigation = [view.canGoBack, view.canGoForward]
        if navigation != lastNavigationState {
            lastNavigationState = navigation
            changed = true
        }
        if changed { invalidate() }
    }

    /// `SIX_UI_DEBUG=1`: what `setFrame` asked for against where the `WKView`'s `HWND` actually is,
    /// which is the first thing to rule out whenever a page looks misplaced.
    ///
    /// Only when it changes. This runs on every repaint, and `SIX_UI_DEBUG` is the flag anyone
    /// debugging the DPI shim reaches for first — a line per frame buries the one line they came
    /// for under a rail that redraws on every focus change and every wheel notch.
    private func traceActualFrame(of webView: RailWebView, parent: HWND, intended: RECT) {
        guard ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1", let childHwnd = webView.hwnd else { return }
        let key = [intended.left, intended.top, intended.right, intended.bottom]
        guard key != lastTracedFrame else { return }
        lastTracedFrame = key
        var actual = RECT()
        GetWindowRect(childHwnd, &actual)
        var topLeft = POINT(x: actual.left, y: actual.top)
        var bottomRight = POINT(x: actual.right, y: actual.bottom)
        ScreenToClient(parent, &topLeft)
        ScreenToClient(parent, &bottomRight)
        let message = "[six] live view: intended=\(intended) actual(client)=" +
            "(\(topLeft.x),\(topLeft.y))-(\(bottomRight.x),\(bottomRight.y))\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func makeWebView(for tabID: Foundation.UUID, parent: HWND, frame: RECT) -> RailWebView? {
        // The active profile, because the only column that ever gets a view is the focused one and
        // the focused column is by definition in the strip on screen.
        guard let created = WebEngine.makeView(parent: parent, frame: frame, profile: model.activeProfile) else {
            return nil
        }
        created.onTitleChange = { [weak self] title in
            self?.model.setTitle(title, for: tabID)
            self?.invalidate()
        }
        created.onURLChange = { [weak self] url in
            self?.model.setURL(url, for: tabID)
            self?.invalidate()
        }
        // A navigation finished: whatever was known about the page that was here is not about this
        // one, and this one has not been looked at yet.
        created.onFinishNavigation = { [weak self] in
            guard let self, let view = webViews[tabID] else { return }
            translation.pageChanged(tabID)
            translation.consider(view, tabID: tabID)
        }
        created.load(model.url(for: tabID))
        webViews[tabID] = created
        return created
    }

    /// `RailModel` knows nothing about `WKView`, so a closed column cannot tear its own view down —
    /// it can only stop being listed, which is what this notices. Against every profile's strip and
    /// not just the one on screen: a column of another profile is out of sight, not closed.
    private func pruneClosedWebViews() {
        let openIDs = model.allTabIDs
        for (id, view) in webViews where !openIDs.contains(id) {
            view.destroy()
            webViews[id] = nil
            translation.forget(id)
        }
    }
}
