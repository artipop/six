import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// The live columns: a real `WKView` for every column the strip is showing, and for half a screen
/// either side of it, kept within the budget `LivePages` sets — the Mac's `LivePageCache` rule,
/// shared with Linux. A view past the budget is destroyed and its column falls back to a picture;
/// a view merely out of sight is hidden rather than rebuilt, so stepping back to it does not reload.
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

        let (live, dropped) = model.settleLivePages()
        for id in dropped { discardWebView(id) }

        if let focused = model.columns.first(where: \.isFocused) {
            syncAddressBarIfNeeded(focusedTabID: focused.id)
        } else {
            addressBarShownTabID = nil
        }

        // The overview draws pictures, not pages: every view goes out of sight, photographed first
        // if it was on screen, so the card it leaves behind looks like the page it was.
        let columns = model.isOverview ? [] : model.columns
        var client = RECT()
        GetClientRect(hwnd, &client)
        var shown: Set<Foundation.UUID> = []
        for column in columns where live.contains(column.id) {
            let body = bodyRect(for: column)
            // A margin column — pinned so that stepping to it finds its page ready — is built and
            // placed, but not shown until some of it is actually inside the window.
            let onScreen = body.right > client.left && body.left < client.right
            guard let view = webViews[column.id] ?? makeWebView(for: column.id, parent: hwnd, frame: body)
            else { continue }
            view.setFrame(body)
            if onScreen {
                view.setVisible(true)
                shown.insert(column.id)
            }
        }
        for (id, view) in webViews where !shown.contains(id) {
            if visibleViews.contains(id) { captureThumbnail(id) }
            view.setVisible(false)
        }
        visibleViews = shown

        if let focused = columns.first(where: \.isFocused), let view = webViews[focused.id] {
            traceActualFrame(of: view, parent: hwnd, intended: bodyRect(for: focused))
        }
    }

    /// What the live pages currently say they are, on a timer (`RailWindow.pageStateTimer`).
    ///
    /// Three things this front draws are the page's rather than the rail's — the title on the card,
    /// the address in the bar, and whether back and forward can do anything — and WebKit announces
    /// none of them at a moment that is late enough to be true: `didFinishNavigation` fires with the
    /// old title still in place, and pushing onto the back-forward list is not announced at all.
    /// Polling four times a second is what the Mac gets from `WebPage`'s observation for free. Every
    /// live view, not only the focused one: the cards beside it carry titles too.
    ///
    /// It repaints only on a change, so an idle window is idle. It is also where a page that finished
    /// loading a moment ago is photographed, once it has had time to draw.
    func refreshLivePageState() {
        var changed = false
        for (id, view) in webViews {
            let title = view.title
            if !title.isEmpty, title != model.title(for: id) || model.awaitsTitle(id) {
                model.setTitle(title, for: id)
                changed = true
            }
            let url = view.url
            if !url.isEmpty, url != model.url(for: id) {
                model.setURL(url, for: id)
                changed = true
            }
        }
        if let view = focusedWebView {
            let navigation = [view.canGoBack, view.canGoForward]
            if navigation != lastNavigationState {
                lastNavigationState = navigation
                changed = true
            }
        }
        let now = Date()
        for (id, due) in thumbnailDue where due <= now {
            thumbnailDue[id] = nil
            if visibleViews.contains(id) { captureThumbnail(id) }
        }
        if changed { invalidate() }
    }

    /// A page clicked into is a column focused, the way clicking a card is: WebKit's child `HWND`
    /// takes the click, so the rail only hears about it from the queue (`route`). The click itself
    /// goes on to the page.
    func focusColumnOwning(_ target: HWND) {
        guard let id = webViews.first(where: { _, view in
            guard let child = view.hwnd else { return false }
            return child == target || IsChild(child, target)
        })?.key, id != model.focusedTabID else { return }
        model.focus(id)
        invalidate()
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
            "(\(topLeft.x),\(topLeft.y))-(\(bottomRight.x),\(bottomRight.y)) " +
            "live=\(webViews.count)/\(model.liveBudget) shown=\(visibleViews.count)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private func makeWebView(for tabID: Foundation.UUID, parent: HWND, frame: RECT) -> RailWebView? {
        // The column's own profile rather than the one on screen: the two are the same for anything
        // built here today, and the day they are not, a page in the wrong cookie jar is the bug.
        guard let created = WebEngine.makeView(parent: parent, frame: frame, profile: model.profile(of: tabID)) else {
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
        // one, and this one has not been looked at yet. It is also a visit, and a page worth a new
        // picture once it has had a moment to draw.
        created.onFinishNavigation = { [weak self] in
            guard let self, let view = webViews[tabID] else { return }
            translation.pageChanged(tabID)
            translation.consider(view, tabID: tabID)
            model.pageDidFinishLoading(tabID, url: view.url, title: view.title)
            thumbnailDue[tabID] = Date().addingTimeInterval(1.5)
            model.permissionSelfTestIfAsked(tabID)
            invalidate()
        }
        created.onMediaRequest = { [weak self] request in
            guard let self else { return request.answer(false) }
            model.requestMedia(tabID: tabID, origin: request.origin, camera: request.camera,
                               microphone: request.microphone, answer: request.answer)
            invalidate()
        }
        created.load(model.url(for: tabID))
        webViews[tabID] = created
        return created
    }

    /// Past the budget: the page is given back, and the column keeps its place, its title, its
    /// address and — if it was on screen a moment ago — its picture.
    private func discardWebView(_ id: Foundation.UUID) {
        guard let view = webViews[id] else { return }
        if visibleViews.contains(id) { captureThumbnail(id) }
        view.destroy()
        webViews[id] = nil
        visibleViews.remove(id)
        thumbnailDue[id] = nil
        translation.forget(id)
        model.pageDiscarded(id)
        Log.info(.pages, "discarded \(id.uuidString.prefix(8)), \(webViews.count) of \(model.liveBudget) live")
    }

    /// `RailModel` knows nothing about `WKView`, so a closed column cannot tear its own view down —
    /// it can only stop being listed, which is what this notices. Against every profile's strip and
    /// not just the one on screen: a column of another profile is out of sight, not closed.
    private func pruneClosedWebViews() {
        let openIDs = model.allTabIDs
        for (id, view) in webViews where !openIDs.contains(id) {
            view.destroy()
            webViews[id] = nil
            visibleViews.remove(id)
            thumbnailDue[id] = nil
            translation.forget(id)
        }
        for id in thumbnails.keys where !openIDs.contains(id) { forgetThumbnail(id) }
    }
}
