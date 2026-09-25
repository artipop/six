import CStripInterop
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
/// the Mac cannot tell one from a plain click, and here the row sees the button before the page does.
extension StripWindow {
    /// `window.open` or a `target=_blank` link: a column in front, holding a view made on the
    /// configuration WebKit handed over. The page loads its own request into it.
    func openPageWindow(_ configuration: WKPageConfigurationRef, url: String,
                        from source: Foundation.UUID) -> StripWebView? {
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
        let control = kind == WM_LBUTTONDOWN && SixStripKeyDown(Int32(VK_CONTROL)) != 0
        guard middle || control else { return false }
        guard let entry = webViewEntry(owning: target), let link = entry.view.hoveredLink,
              Self.opensInColumn(link) || Self.isExternal(link) else {
            if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
                let known = webViewEntry(owning: target) != nil
                FileHandle.standardError.write(Data(
                    "[six] \(middle ? "middle" : "ctrl") click on \(known ? "a page" : "no page"): no link under it\n".utf8))
            }
            return false
        }
        let forward = control && SixStripKeyDown(Int32(VK_SHIFT)) != 0
        swallowedRelease = UINT(middle ? WM_MBUTTONUP : WM_LBUTTONUP)
        // A link to somebody else's app has no column to open in, behind or otherwise: the click is
        // the same question a plain click on it asks.
        if Self.isExternal(link) {
            offerExternalLink(link, gesture: true, from: entry.tabID)
            return true
        }
        openLink(link, from: entry.tabID, focus: forward)
        return true
    }

    /// A link in a column of its own, right of the one it was in — behind, or in front. A middle
    /// click, a `Ctrl`-click and the context menu's Open Link Behind all end here, the way the Mac's
    /// three routes all end at `openInNewWindow(_:from:background:)`.
    func openLink(_ link: String, from source: Foundation.UUID, focus: Bool) {
        guard Self.opensInColumn(link) else { return }
        let opened = model.openColumn(url: link, from: source, focus: focus)
        carriers[opened] = source
        Log.info(.pages, "a link opened \(focus ? "beside, in front" : "behind")")
        invalidate()
    }

    /// What a new column can show. Narrower than `ExternalScheme.own`, which also lists schemes only
    /// the Mac serves (`six:`, the extension and MCP-app ones); what is in neither list is somebody
    /// else's app's, and goes to `offerExternalLink`.
    private static func opensInColumn(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "about", "data", "blob"].contains(scheme)
    }

    private static func isExternal(_ link: String) -> Bool {
        URL(string: link).map(ExternalScheme.isExternal) ?? false
    }

    /// A page wants somebody else's app: `mailto:`, `magnet:`, whatever an app claimed.
    ///
    /// The Mac hands these to the system on a click without asking, which is LaunchServices' answer
    /// to its own security. Windows' is not the same: a protocol handler opened without a question is
    /// how `ms-msdt:` became an exploit, and every Windows browser asks. So this asks, with the app's
    /// name — "Open this link in Mail?" — and only after a click: a page that tries it on its own is
    /// refused, and the log says so. Nothing claims the scheme, and the answer is a sentence rather
    /// than a question. The log keeps the scheme and the app, never the address.
    func offerExternalLink(_ address: String, gesture: Bool, from tabID: Foundation.UUID) {
        guard let scheme = URL(string: address)?.scheme?.lowercased() else { return }
        guard gesture else {
            Log.info(.pages, "a page tried to open a \(scheme): link without a click; refused")
            return
        }
        let host = URL(string: model.url(for: tabID))?.host() ?? "This page"
        let question: String
        let target: String
        switch Self.handler(for: scheme) {
        case .none:
            Log.info(.pages, "a \(scheme): link was clicked, and no app opens those")
            askPage(StripWebView.PageDialog(host: host, message: "No app on this computer opens \(scheme): links.",
                                           kind: .alert, answer: { _ in }), tabID: tabID)
            return
        case .picker:
            question = "Open this link in another app? Windows will ask which one."
            target = "the app picker"
        case .app(let app):
            question = "Open this link in \(app)?"
            target = app
        }
        Log.info(.pages, "a \(scheme): link asks to be opened in \(target)")
        let shown = address.count > 300 ? String(address.prefix(300)) + "…" : address
        askPage(StripWebView.PageDialog(host: host, message: "\(question)\n\n\(shown)", kind: .confirm) { value in
            guard value != nil else { return }
            _ = address.withCString(encodedAs: UTF16.self) { SixStripShellOpen($0) }
            Log.info(.pages, "a \(scheme): link was handed to \(target)")
        }, tabID: tabID)
    }

    /// Who opens a scheme on this machine, as Windows would put it.
    enum Handler: Equatable {
        /// An app, by its own name — "Mail", "qBittorrent".
        case app(String)
        /// The scheme is one Windows knows, and nobody was picked for it — `mailto:` on a machine with
        /// no mail app chosen — so what would run is Windows' "how do you want to open this?"
        /// (`OpenWith.exe`). Measured: the name Windows gives for that case is the picker's own,
        /// "Choose an app" in the system's language, and "Open this link in Choose an app?" says
        /// nothing true.
        case picker
        /// Nothing claims it.
        case none
    }

    /// `ASSOCF_IS_PROTOCOL`, so the answer is the default the person picked in Settings rather than
    /// whatever registered the scheme last.
    static func handler(for scheme: String) -> Handler {
        guard let name = association(ASSOCSTR_FRIENDLYAPPNAME, for: scheme) else { return .none }
        if let executable = association(ASSOCSTR_EXECUTABLE, for: scheme),
           executable.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
               .split(separator: "\\").last?.lowercased() == "openwith.exe" {
            return .picker
        }
        return .app(name)
    }

    private static func association(_ what: ASSOCSTR, for scheme: String) -> String? {
        var size = DWORD(1024)
        var buffer = [WCHAR](repeating: 0, count: Int(size))
        let result = scheme.withCString(encodedAs: UTF16.self) { name in
            "open".withCString(encodedAs: UTF16.self) { verb in
                AssocQueryStringW(ASSOCF(0x0000_1000), what, name, verb, &buffer, &size)
            }
        }
        guard result >= 0 else { return nil }
        let text = String(decodingCString: buffer, as: UTF16.self)
        return text.isEmpty ? nil : text
    }
}
