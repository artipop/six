import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// A single, plain Win32 `EDIT` control showing and editing the focused column's URL — the one piece
/// of UI that turns the rail from "loads its start page and nothing else" into something a person can
/// actually browse with. One bar for the whole window, not one per column, the same "one live thing"
/// simplification `RailLiveView` already makes for the `WKView` itself: the bar shows whichever column
/// is focused and is retargeted, not rebuilt, as focus moves.
extension RailWindow {
    private static let editClassName = "EDIT"
    private static let margin: Int32 = 8

    /// Created once, right after the main window itself — an `EDIT` control needs a parent `HWND` to
    /// exist first, so this cannot happen any earlier than `create(instance:)` already has one.
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

        // Subclassing: swap in a `WNDPROC` that only intercepts Enter and forwards everything else to
        // the real `EDIT` control's own procedure — the same shape `sixty`'s MiniBrowserSwift
        // prototype already uses for its own address bar.
        let oldProc = GetWindowLongPtrW(created, GWLP_WNDPROC)
        originalAddressBarProc = unsafeBitCast(oldProc, to: WNDPROC.self)
        // `addressBarSubclassProc`, named bare, is a plain (16-byte, "thick") Swift function value —
        // typing this `let` as `WNDPROC` is what makes the compiler perform the thin-to-C-function-
        // pointer conversion `wc.lpfnWndProc = railWindowProc` gets for free from a direct assignment
        // to a `@convention(c)`-typed property; skipping straight to `unsafeBitCast` on the bare name
        // instead bitcasts the wrong (thick, 16-byte) representation into an 8-byte `LONG_PTR` and
        // crashes with "Can't unsafeBitCast between types of different sizes".
        let subclassProc: WNDPROC = addressBarSubclassProc
        _ = SetWindowLongPtrW(created, GWLP_WNDPROC, unsafeBitCast(subclassProc, to: LONG_PTR.self))

        layoutAddressBar()
    }

    /// Positions the bar in its own strip, directly below the workspace label — called on
    /// `WM_SIZE`, since it is the one piece of chrome sized against the window's own width rather
    /// than `NiriLayout`'s viewport.
    func layoutAddressBar() {
        guard let hwnd, let addressBarHwnd else { return }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let top = Int32(Self.workspaceLabelHeight) + Self.margin / 2
        let height = Int32(Self.addressBarStripHeight) - Self.margin
        MoveWindow(addressBarHwnd, Self.margin, top, client.right - 2 * Self.margin, height, true)
    }

    /// Called from `updateLiveView` on every repaint: retargets the bar's text to whichever column is
    /// now focused, but only when focus actually moved — never while someone is mid-keystroke typing
    /// a URL into it, which every other repaint (a page's title or URL changing, a column opening
    /// elsewhere) would otherwise stomp on.
    func syncAddressBarIfNeeded(focusedTabID: Foundation.UUID) {
        guard let addressBarHwnd, addressBarShownTabID != focusedTabID else { return }
        addressBarShownTabID = focusedTabID
        _ = model.url(for: focusedTabID).withCString(encodedAs: UTF16.self) { SetWindowTextW(addressBarHwnd, $0) }
    }

    /// Enter in the address bar: read its text, add a scheme if it looks like a bare host, and load
    /// it into the focused column's `WKView` — the only way, right now, to navigate this front
    /// anywhere but a column's own start page.
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
