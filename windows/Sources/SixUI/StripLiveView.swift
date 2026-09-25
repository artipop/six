import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// The live columns: a real `WKView` for every column the strip is showing, and for half a screen
/// either side of it, kept within the budget `LivePages` sets — the Mac's `LivePageCache` rule,
/// shared with Linux. A view past the budget is destroyed and its column falls back to a picture;
/// a view merely out of sight is hidden rather than rebuilt, so stepping back to it does not reload.
extension StripWindow {
    /// Resyncing from the model on every repaint, rather than threading a notification through
    /// every mutation that could move focus: the model is the source of truth either way.
    func updateLiveView() {
        guard let hwnd else { return }
        pruneClosedWebViews()

        // The translation banner is a second line of chrome that comes and goes, so the row's
        // canvas is not a constant. Told here rather than only on `WM_SIZE`, because nothing
        // resizes when a translation starts.
        if topChromeHeight != lastChromeHeight {
            lastChromeHeight = topChromeHeight
            var client = RECT()
            GetClientRect(hwnd, &client)
            _ = model.updateViewport(CGSize(width: Int(client.right),
                                            height: max(0, Int(client.bottom) - Int(topChromeHeight))))
        }

        // The bar follows the row on every repaint, because a profile switch onto an empty strip is
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

    /// What the live pages currently say they are, on a timer (`StripWindow.pageStateTimer`).
    ///
    /// Three things this front draws are the page's rather than the row's — the title on the card,
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
        // How far each page has got, for the lines under the address and across the cards. In steps
        // of a twentieth, so a page trickling in repaints a handful of times rather than four a second.
        for (id, view) in webViews {
            let progress: Double? = view.isLoading ? view.estimatedProgress : nil
            let known = loadProgress[id]
            if (progress == nil) != (known == nil) || abs((progress ?? 0) - (known ?? 0)) >= 0.05 {
                loadProgress[id] = progress
                changed = true
            }
        }
        for id in loadProgress.keys where webViews[id] == nil { loadProgress[id] = nil }
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
    /// takes the click, so the row only hears about it from the queue (`route`). The click itself
    /// goes on to the page.
    func focusColumnOwning(_ target: HWND) {
        guard let id = webViewEntry(owning: target)?.tabID, id != model.focusedTabID else { return }
        model.focus(id)
        invalidate()
    }

    /// The live column whose page this `HWND` is, or is inside — WebKit's child window takes a click,
    /// so a message aimed at a page names that window and not the column.
    func webViewEntry(owning target: HWND) -> (tabID: Foundation.UUID, view: StripWebView)? {
        guard let entry = webViews.first(where: { _, view in
            guard let child = view.hwnd else { return false }
            return child == target || IsChild(child, target)
        }) else { return nil }
        return (entry.key, entry.value)
    }

    /// `SIX_UI_DEBUG=1`: what `setFrame` asked for against where the `WKView`'s `HWND` actually is,
    /// which is the first thing to rule out whenever a page looks misplaced.
    ///
    /// Only when it changes. This runs on every repaint, and `SIX_UI_DEBUG` is the flag anyone
    /// debugging the DPI shim reaches for first — a line per frame buries the one line they came
    /// for under a row that redraws on every focus change and every wheel notch.
    private func traceActualFrame(of webView: StripWebView, parent: HWND, intended: RECT) {
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

    private func makeWebView(for tabID: Foundation.UUID, parent: HWND, frame: RECT) -> StripWebView? {
        // The column's own profile rather than the one on screen: the two are the same for anything
        // built here today, and the day they are not, a page in the wrong cookie jar is the bug.
        guard let created = WebEngine.makeView(parent: parent, frame: frame, profile: model.profile(of: tabID)) else {
            return nil
        }
        wire(created, tabID: tabID)
        created.load(model.url(for: tabID))
        webViews[tabID] = created
        return created
    }

    /// Everything a live column's view tells the row. Separate from `makeWebView` because a view is
    /// not only made for a column: a page opening a window makes one too (`openPageWindow`), and that
    /// one loads its own request rather than the column's address.
    func wire(_ created: StripWebView, tabID: Foundation.UUID) {
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
            // It showed a page: whatever it was opened to carry, it is a window now.
            carriers[tabID] = nil
            translation.pageChanged(tabID)
            // Six's "this page didn't open" is not a visit and not a page to translate; it is still
            // worth a picture, since it is what the column now looks like.
            if view.isShowingFailure {
                thumbnailDue[tabID] = Date().addingTimeInterval(1.5)
                invalidate()
                return
            }
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
        created.onDialog = { [weak self] dialog in
            guard let self else { return dialog.answer(nil) }
            askPage(dialog, tabID: tabID)
        }
        created.onChooseFiles = { [weak self] choice in
            guard let self else { return choice.answer(nil) }
            chooseFiles(choice, tabID: tabID)
        }
        created.onDownload = { [weak self] download in
            guard let self else { return }
            downloads.adopt(download)
            closeIfOnlyCarried(tabID)
        }
        created.onExternalLink = { [weak self] address, gesture in
            self?.offerExternalLink(address, gesture: gesture, from: tabID)
        }
        created.onOpenLinkBehind = { [weak self] link in
            self?.openLink(link, from: tabID, focus: false)
        }
        created.onCreatePage = { [weak self] configuration, url in
            self?.openPageWindow(configuration, url: url, from: tabID)
        }
        // `window.close()`: the column goes, and its view with it on the next repaint.
        created.onClose = { [weak self] in
            guard let self else { return }
            Log.info(.pages, "a page closed its own window")
            model.closeColumn(tabID)
            invalidate()
        }
    }

    /// Past the budget: the page is given back, and the column keeps its place, its title, its
    /// address and — if it was on screen a moment ago — its picture.
    private func discardWebView(_ id: Foundation.UUID) {
        guard let view = webViews[id] else { return }
        if visibleViews.contains(id) { captureThumbnail(id) }
        forgetPageDialogs(for: id)
        view.destroy()
        webViews[id] = nil
        visibleViews.remove(id)
        thumbnailDue[id] = nil
        translation.forget(id)
        model.pageDiscarded(id)
        Log.info(.pages, "discarded \(id.uuidString.prefix(8)), \(webViews.count) of \(model.liveBudget) live")
    }

    /// `StripModel` knows nothing about `WKView`, so a closed column cannot tear its own view down —
    /// it can only stop being listed, which is what this notices. Against every profile's strip and
    /// not just the one on screen: a column of another profile is out of sight, not closed.
    private func pruneClosedWebViews() {
        let openIDs = model.allTabIDs
        for (id, view) in webViews where !openIDs.contains(id) {
            forgetPageDialogs(for: id)
            view.destroy()
            webViews[id] = nil
            visibleViews.remove(id)
            thumbnailDue[id] = nil
            translation.forget(id)
        }
        for id in thumbnails.keys where !openIDs.contains(id) { forgetThumbnail(id) }
    }
}
