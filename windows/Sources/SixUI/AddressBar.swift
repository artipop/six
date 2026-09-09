import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// A plain Win32 `EDIT` control showing and editing the focused column's URL, sunk into the pill
/// `RailChrome` draws behind it. One bar for the whole window rather than one per column — the same
/// "one live thing" simplification `RailLiveView` makes — retargeted, not rebuilt, as focus moves.
///
/// The control is borderless and paints in the bar's own colours (`WM_CTLCOLOREDIT`, answered by
/// `RailWindow.handle`), because the only part of a Win32 `EDIT` that cannot be styled is its
/// frame: `WS_EX_CLIENTEDGE` draws a Windows 95 sunken border no message can talk it out of.
extension RailWindow {
    private static let editClassName = "EDIT"

    /// Created from `create(instance:)`, which is the earliest a parent `HWND` exists to hang it on.
    func ensureAddressBar(instance: HINSTANCE) {
        guard let hwnd, addressBarHwnd == nil else { return }

        let created: HWND? = Self.editClassName.withCString(encodedAs: UTF16.self) { classPtr in
            RailModel.startURL.withCString(encodedAs: UTF16.self) { textPtr in
                CreateWindowExW(
                    0, classPtr, textPtr,
                    DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL),
                    0, 0, 0, 0, hwnd, nil, instance, nil
                )
            }
        }
        guard let created else { return }
        addressBarHwnd = created

        // The same `GWLP_USERDATA` dance `railWindowProc` uses for the main window, minus the
        // `WM_NCCREATE` step — there is no `CREATESTRUCTW` to pull it from here, so it is set
        // directly, once, right after creation, before any message the subclass proc below cares
        // about can arrive.
        SixRailSetUserData(created, Unmanaged.passUnretained(self).toOpaque())

        // Wrap, don't replace: the subclass proc intercepts Enter and forwards the rest to `EDIT`'s
        // own, the same shape `sixty`'s MiniBrowserSwift address bar uses.
        let oldProc = GetWindowLongPtrW(created, GWLP_WNDPROC)
        originalAddressBarProc = unsafeBitCast(oldProc, to: WNDPROC.self)
        // The `WNDPROC` annotation is load-bearing: it is what converts the thick (16-byte) Swift
        // function value to a C function pointer. `unsafeBitCast` on the bare name instead casts the
        // thick representation into an 8-byte `LONG_PTR` and traps on the size mismatch.
        let subclassProc: WNDPROC = addressBarSubclassProc
        _ = SetWindowLongPtrW(created, GWLP_WNDPROC, unsafeBitCast(subclassProc, to: LONG_PTR.self))

        refreshFonts()
        layoutAddressBar()
    }

    /// The control is inset into the pill so that what shows around it is the pill's rounded edge
    /// and not the control's square one.
    ///
    /// Called on `WM_SIZE`, on a DPI change, and from every repaint — the field comes and goes with
    /// the focused window, and a profile switch onto an empty rail is a repaint and nothing else. It
    /// compares before it moves anything: `MoveWindow` on every paint would repaint the `EDIT`
    /// underneath the caret sixty times a second.
    func layoutAddressBar() {
        guard let addressBarHwnd else { return }
        let pill = chromeLayout().addressPill
        guard pill.right > pill.left else {
            if addressBarFrame != nil {
                addressBarFrame = nil
                ShowWindow(addressBarHwnd, SW_HIDE)
            }
            return
        }
        let inset = px(10)
        let height = px(18)
        let left = pill.left + inset
        let top = pill.top + (pill.bottom - pill.top - height) / 2
        let width = max(0, pill.right - pill.left - inset * 2)
        let frame = RECT(left: left, top: top, right: left + width, bottom: top + height)
        if let current = addressBarFrame, current.left == frame.left, current.top == frame.top,
           current.right == frame.right, current.bottom == frame.bottom { return }
        addressBarFrame = frame
        MoveWindow(addressBarHwnd, left, top, width, height, true)
        ShowWindow(addressBarHwnd, SW_SHOW)
    }

    /// ⌘L's opposite number. Selects what is there, the way every browser's does, so that typing
    /// replaces the address rather than appending to it.
    func focusAddressBar() {
        guard let addressBarHwnd else { return }
        SetFocus(addressBarHwnd)
        SendMessageW(addressBarHwnd, UINT(EM_SETSEL), 0, -1)
        invalidate()
    }

    /// Runs on every repaint. It retargets when focus moves to another column, and follows the page
    /// when *that* column navigates somewhere — but never while the field has focus, because then
    /// what is in it is half-typed and belongs to the person, not to the page.
    func syncAddressBarIfNeeded(focusedTabID: Foundation.UUID) {
        guard let addressBarHwnd else { return }
        let url = model.url(for: focusedTabID)
        let movedColumn = addressBarShownTabID != focusedTabID
        guard movedColumn || (addressBarShownText != url && GetFocus() != addressBarHwnd) else { return }
        addressBarShownTabID = focusedTabID
        addressBarShownText = url
        _ = url.withCString(encodedAs: UTF16.self) { SetWindowTextW(addressBarHwnd, $0) }
    }

    /// Enter in the address bar.
    func navigateFromAddressBar() {
        guard let addressBarHwnd, let focusedID = model.columns.first(where: \.isFocused)?.id,
              let webView = webViews[focusedID] else { return }

        let length = Int(GetWindowTextLengthW(addressBarHwnd))
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        _ = GetWindowTextW(addressBarHwnd, &buffer, Int32(buffer.count))
        let typed = String(decoding: buffer.prefix(length), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let urlString = Self.address(from: typed)

        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            let message = "[six] navigate: focusedID=\(focusedID) typed=\(typed) url=\(urlString)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        model.setURL(urlString, for: focusedID)
        addressBarShownText = urlString
        webView.load(urlString)
        // Back to the rail, so the arrow keys are the rail's again the moment a page starts loading
        // — the Mac hands focus to the page for the same reason.
        if let hwnd { SetFocus(hwnd) }
        invalidate()
    }

    /// What was typed, as something to load. A word with no dot in it is a search rather than a
    /// host, which is the one piece of `SearchEngine` this front needs and the only piece of it that
    /// can be written down in three lines; the Mac's version knows about engines, suggestions and
    /// the search field's own history.
    static func address(from typed: String) -> String {
        if typed.contains("://") { return typed }
        let head = typed.split(separator: "/").first.map(String.init) ?? typed
        if head.contains("."), !head.contains(" ") { return "https://" + typed }
        if typed == "localhost" || typed.hasPrefix("localhost:") { return "http://" + typed }
        let query = typed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? typed
        return "https://duckduckgo.com/?q=" + query
    }
}

/// The address bar's own subclass `WNDPROC` — `nonisolated` for the same reason `railWindowProc` is:
/// a C function pointer carries no actor isolation, only what `MainActor.assumeIsolated` hands back
/// after recovering it can.
private nonisolated func addressBarSubclassProc(
    _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    guard let hwnd, let stored = SixRailGetUserData(hwnd) else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    let window = Unmanaged<RailWindow>.fromOpaque(stored).takeUnretainedValue()

    switch Int32(message) {
    case WM_KEYDOWN where wParam == WPARAM(VK_RETURN):
        MainActor.assumeIsolated { window.navigateFromAddressBar() }
        return 0
    case WM_KEYDOWN where wParam == WPARAM(VK_ESCAPE):
        // Give the address back and hand the keyboard to the rail: an address bar you cannot leave
        // is one that swallows every rail shortcut until something else is clicked.
        MainActor.assumeIsolated {
            window.addressBarShownTabID = nil
            if let parent = window.hwnd { SetFocus(parent) }
            window.invalidate()
        }
        return 0
    case WM_CHAR where wParam == WPARAM(VK_RETURN) || wParam == WPARAM(VK_ESCAPE):
        // A single-line `EDIT` beeps at these, having no use for them; they were handled above.
        return 0
    case WM_SETFOCUS, WM_KILLFOCUS:
        MainActor.assumeIsolated { window.invalidate() } // the pill's focus ring
    default:
        break
    }

    let original = MainActor.assumeIsolated { window.originalAddressBarProc }
    guard let original else { return DefWindowProcW(hwnd, message, wParam, lParam) }
    return CallWindowProcW(original, hwnd, message, wParam, lParam)
}
