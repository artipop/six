import Foundation
import SixBrowser
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

        let columns = model.columns
        guard let focused = columns.first(where: \.isFocused) else { return }
        syncAddressBarIfNeeded(focusedTabID: focused.id)
        let bodyRect = Self.bodyRect(for: focused.frame)

        let webView = webViews[focused.id] ?? makeWebView(for: focused.id, parent: hwnd, frame: bodyRect)
        guard let webView else { return }

        for (id, view) in webViews where id != focused.id {
            view.setVisible(false)
        }
        webView.setFrame(bodyRect)
        webView.setVisible(true)
        traceActualFrame(of: webView, parent: hwnd, intended: bodyRect)
    }

    /// `SIX_UI_DEBUG=1`: what `setFrame` asked for against where the `WKView`'s `HWND` actually is,
    /// which is the first thing to rule out whenever a page looks misplaced.
    private func traceActualFrame(of webView: RailWebView, parent: HWND, intended: RECT) {
        guard ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1", let childHwnd = webView.hwnd else { return }
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
        guard let created = WebEngine.makeView(parent: parent, frame: frame) else { return nil }
        created.onTitleChange = { [weak self] title in
            self?.model.setTitle(title, for: tabID)
            self?.invalidate()
        }
        created.onURLChange = { [weak self] url in
            self?.model.setURL(url, for: tabID)
            self?.invalidate()
        }
        created.load(model.url(for: tabID))
        webViews[tabID] = created
        return created
    }

    /// `RailModel` knows nothing about `WKView`, so a closed column cannot tear its own view down —
    /// it can only stop being listed, which is what this notices.
    private func pruneClosedWebViews() {
        let openIDs = Set(model.columns.map(\.id))
        for (id, view) in webViews where !openIDs.contains(id) {
            view.destroy()
            webViews[id] = nil
        }
    }

    /// Below the header: leaving that strip GDI's rather than the page's is what keeps the close
    /// box clickable instead of covered by a child `HWND`. Built on `cardRect`, the same conversion
    /// `draw` and `handleClick` use, so the three cannot disagree.
    static func bodyRect(for frame: CGRect) -> RECT {
        let card = cardRect(for: frame)
        return RECT(left: card.left, top: card.top + Int32(headerHeight), right: card.right, bottom: card.bottom)
    }
}
