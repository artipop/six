import Foundation
import SixBrowser
import WinSDK

/// The one live column: a real `WKView` for the focused tab, created lazily and kept alive — not
/// torn down and rebuilt — as focus moves off and back on to it, so switching back to a tab does
/// not reload it. No live-page budget yet: every other front's version of "more than one column
/// can be live at once" is future work here too, tracked in docs/windows.md, not a gap specific to
/// this front.
extension RailWindow {
    /// Called from `WM_PAINT`, just before `paint()` — deliberately outside `BeginPaint`/`EndPaint`,
    /// on the theory (tried, did not resolve the "Known issues" rendering bug alone, kept anyway
    /// since it is still the more correct place for it) that creating/positioning a hardware-
    /// composited child window mid-paint could confuse the compositor. The model is the source of
    /// truth for which column is focused, so resyncing on every repaint is simpler than threading a
    /// second notification path through every mutation that could change focus.
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

    /// `SIX_UI_DEBUG=1`: what rect `setFrame` asked for versus what the `WKView`'s `HWND` actually
    /// ended up at, in the parent's own client coordinates — the two are not obviously the same
    /// thing if WebKit's own internal resize logic ever overrides what `MoveWindow` set.
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

    /// A column the rail closed still has a `webViews` entry until this runs: `RailModel` knows
    /// nothing about `WKView`, so closing a column cannot tell this file to tear one down directly
    /// — it can only stop listing the column, which is what this checks for.
    private func pruneClosedWebViews() {
        let openIDs = Set(model.columns.map(\.id))
        for (id, view) in webViews where !openIDs.contains(id) {
            view.destroy()
            webViews[id] = nil
        }
    }

    /// Below the header a card draws its title and "×" in — leaving that strip GDI's, not the live
    /// page's, is what keeps the close box clickable instead of covered by a child `HWND`. Built on
    /// `cardRect`, the same conversion `draw` and `handleClick` use, so the live view lines up with
    /// what is actually drawn on screen.
    static func bodyRect(for frame: CGRect) -> RECT {
        let card = cardRect(for: frame)
        return RECT(left: card.left, top: card.top + Int32(headerHeight), right: card.right, bottom: card.bottom)
    }
}
