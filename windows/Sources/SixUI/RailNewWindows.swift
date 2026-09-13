import CRailInterop
import CWebKit2
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// A second window: the ones a page opens, and the ones a click asks for.
///
/// The Mac's rule, [links.md](../../../docs/links.md): a window a page opened for itself comes forward,
/// because it was opened to be looked at; a link opened on purpose goes behind, the focus staying on
/// the page being read. Both land right of the column that asked.
///
/// Two differences from the Mac, both in this front's favour. A window a page opens is a real one:
/// WebKit asks `createNewPage` for a page and gets a view made on its own configuration, so the popup
/// keeps `window.opener` and can go home — the Mac cancels the navigation and loads the address in a
/// fresh column, which is why a sign-in popup there cannot. And a middle click opens a link behind:
/// the Mac cannot tell one from a plain click, and here the rail sees the button before the page does.
extension RailWindow {
    /// `window.open` or a `target=_blank` link: a column in front, holding a view made on the
    /// configuration WebKit handed over. The page loads its own request into it.
    func openPageWindow(_ configuration: WKPageConfigurationRef, url: String,
                        from source: Foundation.UUID) -> RailWebView? {
        guard let hwnd else { return nil }
        let tabID = model.openColumn(url: url, from: source, focus: true)
        // A pixel for a start: the repaint this asks for puts it over its card, the way it does every
        // view (`updateLiveView`), and that first `setFrame` is what the scale shim needs anyway.
        guard let view = WebEngine.makeView(parent: hwnd, frame: RECT(left: 0, top: 0, right: 1, bottom: 1),
                                            configuration: configuration) else {
            model.closeColumn(tabID)
            return nil
        }
        wire(view, tabID: tabID)
        webViews[tabID] = view
        carriers[tabID] = source
        Log.info(.pages, "a page opened a window beside itself")
        invalidate()
        return view
    }

    /// A middle click, or a `Ctrl`-click, on a link: the link in a column behind, and `Ctrl`+`Shift`
    /// in front — every Windows browser's reading of those clicks. `true` takes the press, and the
    /// release after it is taken too (`swallowedRelease`), so the page never sees half a click.
    ///
    /// Read against the link the page last said was under the pointer, because nothing WebKit's C API
    /// tells a navigation says which button or keys were behind it. Anything that is not a link, and
    /// any other click, goes on to the page as it always did.
    func openLinkIfAsked(_ message: MSG, target: HWND) -> Bool {
        let kind = Int32(message.message)
        let middle = kind == WM_MBUTTONDOWN
        let control = kind == WM_LBUTTONDOWN && SixRailKeyDown(Int32(VK_CONTROL)) != 0
        guard middle || control else { return false }
        guard let entry = webViewEntry(owning: target), let link = entry.view.hoveredLink,
              Self.opensInColumn(link) else {
            if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
                let known = webViewEntry(owning: target) != nil
                FileHandle.standardError.write(Data(
                    "[six] \(middle ? "middle" : "ctrl") click on \(known ? "a page" : "no page"): no link under it\n".utf8))
            }
            return false
        }
        let forward = control && SixRailKeyDown(Int32(VK_SHIFT)) != 0
        swallowedRelease = UINT(middle ? WM_MBUTTONUP : WM_LBUTTONUP)
        let opened = model.openColumn(url: link, from: entry.tabID, focus: forward)
        carriers[opened] = entry.tabID
        Log.info(.pages, "a link opened \(forward ? "beside, in front" : "behind")")
        invalidate()
        return true
    }

    /// What a new column can show. Everything else — `mailto:`, `magnet:`, a scheme an app claimed — is
    /// somebody else's to open, and handing it to the system is a step of its own, with a question in
    /// front of it on this platform (docs/parity.md); until then that click goes to the page.
    private static func opensInColumn(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "about", "data", "blob"].contains(scheme)
    }
}
