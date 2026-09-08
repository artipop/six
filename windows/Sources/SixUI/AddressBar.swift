import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// A plain Win32 `EDIT` control showing and editing the focused column's URL. One bar for the whole
/// window rather than one per column — the same "one live thing" simplification `RailLiveView`
/// makes — retargeted, not rebuilt, as focus moves.
extension RailWindow {
    private static let editClassName = "EDIT"
    private static let margin: Int32 = 8

    /// Created from `create(instance:)`, which is the earliest a parent `HWND` exists to hang it on.
    func ensureAddressBar(instance: HINSTANCE) {
        guard let hwnd, addressBarHwnd == nil else { return }

        let created: HWND? = Self.editClassName.withCString(encodedAs: UTF16.self) { classPtr in
            RailModel.startURL.withCString(encodedAs: UTF16.self) { textPtr in
                CreateWindowExW(
                    DWORD(WS_EX_CLIENTEDGE), classPtr, textPtr,
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

        layoutAddressBar()
    }

    /// On `WM_SIZE`: the one piece of chrome sized against the window's own width rather than
    /// `NiriLayout`'s viewport.
    func layoutAddressBar() {
        guard let hwnd, let addressBarHwnd else { return }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let top = Int32(Self.workspaceLabelHeight) + Self.margin / 2
        let height = Int32(Self.addressBarStripHeight) - Self.margin
        MoveWindow(addressBarHwnd, Self.margin, top, client.right - 2 * Self.margin, height, true)
    }

    /// Runs on every repaint, so it retargets only when focus actually moved — otherwise a page's
    /// own title or URL callback would stomp on a half-typed address.
    func syncAddressBarIfNeeded(focusedTabID: Foundation.UUID) {
        guard let addressBarHwnd, addressBarShownTabID != focusedTabID else { return }
        addressBarShownTabID = focusedTabID
        _ = model.url(for: focusedTabID).withCString(encodedAs: UTF16.self) { SetWindowTextW(addressBarHwnd, $0) }
    }

    /// Enter in the address bar. The only way, right now, to navigate anywhere but a start page.
    func navigateFromAddressBar() {
        guard let addressBarHwnd, let focusedID = model.columns.first(where: \.isFocused)?.id,
              let webView = webViews[focusedID] else { return }

        let length = Int(GetWindowTextLengthW(addressBarHwnd))
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        _ = GetWindowTextW(addressBarHwnd, &buffer, Int32(buffer.count))
        var urlString = String(decoding: buffer.prefix(length), as: UTF16.self)
        if !urlString.contains("://") { urlString = "https://" + urlString }

        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            let message = "[six] navigate: focusedID=\(focusedID) url=\(urlString)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        model.setURL(urlString, for: focusedID)
        webView.load(urlString)
    }
}

/// The address bar's own subclass `WNDPROC` — `nonisolated` for the same reason `railWindowProc` is:
/// a C function pointer carries no actor isolation, only what `MainActor.assumeIsolated` hands back
/// after recovering it can.
private nonisolated func addressBarSubclassProc(
    _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    if Int32(message) == WM_KEYDOWN, wParam == WPARAM(VK_RETURN), let hwnd, let stored = SixRailGetUserData(hwnd) {
        let window = Unmanaged<RailWindow>.fromOpaque(stored).takeUnretainedValue()
        MainActor.assumeIsolated { window.navigateFromAddressBar() }
        return 0
    }
    guard let hwnd, let stored = SixRailGetUserData(hwnd) else { return DefWindowProcW(hwnd, message, wParam, lParam) }
    let window = Unmanaged<RailWindow>.fromOpaque(stored).takeUnretainedValue()
    let original = MainActor.assumeIsolated { window.originalAddressBarProc }
    guard let original else { return DefWindowProcW(hwnd, message, wParam, lParam) }
    return CallWindowProcW(original, hwnd, message, wParam, lParam)
}
