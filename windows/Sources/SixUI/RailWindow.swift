import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// One Win32 window: the rail, drawn with GDI, and the mouse/wheel input that drives it.
///
/// A `WNDPROC` has to be a plain C function pointer with no captures, so the instance it belongs to
/// cannot be a closure over `self` — it travels through `GWLP_USERDATA` instead, set on
/// `WM_NCCREATE` (the first message any window receives) and read back out on every one after it.
/// That bookkeeping is `CRailInterop`'s; what arrives here is already a `RailWindow`.
@MainActor
public final class RailWindow {
    public private(set) var hwnd: HWND?
    let model = RailModel.shared

    /// Wheel notches accumulate here between messages: a precision mouse or a trackpad can report a
    /// fraction of `WHEEL_DELTA` (120) per message, and the rail should not step twice as fast just
    /// because the hardware reports more often than it turns.
    var wheelRemainderY: Int32 = 0
    var wheelRemainderX: Int32 = 0

    static let className = "SixRailWindow"

    public init() {}

    /// Registers the window class and creates the window. `false` means one of the two Win32 calls
    /// failed — there is nothing more specific to say without `GetLastError`, which is where whoever
    /// runs this next should look.
    public func create(instance: HINSTANCE) -> Bool {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
        wc.lpfnWndProc = railWindowProc
        wc.hInstance = instance
        wc.hCursor = SixRailArrowCursor()
        wc.hbrBackground = nil

        let registered = Self.className.withCString(encodedAs: UTF16.self) { name -> ATOM in
            wc.lpszClassName = name
            return RegisterClassExW(&wc)
        }
        guard registered != 0 else {
            FileHandle.standardError.write(Data("[six] RegisterClassExW failed: \(GetLastError())\n".utf8))
            return false
        }

        let created = Self.className.withCString(encodedAs: UTF16.self) { classNamePtr in
            "six".withCString(encodedAs: UTF16.self) { titlePtr in
                // `CW_USEDEFAULT` for size too, not a fixed 1280×800: a hard-coded size is taller
                // than this dev machine's own 1280×720 display, which is exactly the "sizes are
                // fractions of the viewport, not point constants" lesson CLAUDE.md already has.
                CreateWindowExW(
                    0, classNamePtr, titlePtr, DWORD(WS_OVERLAPPEDWINDOW),
                    Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT),
                    nil, nil, instance, Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }
        guard let created else {
            FileHandle.standardError.write(Data("[six] CreateWindowExW failed: \(GetLastError())\n".utf8))
            return false
        }
        hwnd = created
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[six] window created, hwnd=\(String(describing: created))\n".utf8))
        }
        return true
    }

    public func show() {
        guard let hwnd else { return }
        // Not `SW_SHOWDEFAULT`: that defers to the launching process's own `STARTUPINFO`, which a
        // launch through redirected stdout/stderr often leaves unset — the window is created but
        // never actually shown, silently. `SW_SHOWNORMAL` shows it unconditionally.
        ShowWindow(hwnd, SW_SHOWNORMAL)
        UpdateWindow(hwnd)
        // A SwiftPM executable links as a console-subsystem app by default, so launching this one
        // creates a console window alongside the rail — and the console, not the rail, ends up with
        // keyboard focus: clicks still land on the rail (routed by cursor position), but every key
        // goes to the console instead of `WM_KEYDOWN` here. Claiming both explicitly is the fix
        // until the target links `/SUBSYSTEM:WINDOWS` and there is no console to compete with.
        SetForegroundWindow(hwnd)
        SetFocus(hwnd)
    }

    /// The classic `GetMessage`/`DispatchMessage` pump. Returns once `WM_QUIT` arrives, with the
    /// exit code it carried.
    public func run() -> Int32 {
        // `GetMessageW` imports as `Bool` on this SDK overlay, not the classic tri-state `BOOL`
        // (`0`/`WM_QUIT`, `-1`/error, nonzero/success) — so `WM_QUIT` and an error both read as
        // `false` here and end the loop the same way.
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        return Int32(message.wParam)
    }

    func invalidate() {
        guard let hwnd else { return }
        InvalidateRect(hwnd, nil, false)
    }

    /// Dispatch for one message, called from the free-function `WNDPROC` once it has recovered
    /// `self` from `GWLP_USERDATA`. `nil` is everything left to `DefWindowProcW`.
    func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_DESTROY:
            PostQuitMessage(0)
            return 0

        case WM_ERASEBKGND:
            return 1 // WM_PAINT repaints the whole client area; nothing needs erasing first

        case WM_PAINT:
            paint()
            return 0

        case WM_SIZE:
            let width = Int(SixRailLoWord(lParam))
            let height = Int(SixRailHiWord(lParam))
            if model.updateViewport(CGSize(width: width, height: height)) { invalidate() }
            return 0

        case WM_LBUTTONDOWN:
            handleClick(x: Int(SixRailPointX(lParam)), y: Int(SixRailPointY(lParam)))
            return 0

        case WM_KEYDOWN:
            return handleKeyDown(virtualKey: Int32(wParam), lParam: lParam) ? 0 : nil

        // Every binding this table has is `⌥`-something, and holding Alt is exactly what turns the
        // other key into a *system* key on Windows — `WM_SYSKEYDOWN`, not `WM_KEYDOWN`. Only
        // swallowing it when a binding actually matched leaves `⌥F4`/`⌥Space`/plain `F10` to
        // `DefWindowProcW`, which is what makes them still behave like system keys.
        case WM_SYSKEYDOWN:
            return handleKeyDown(virtualKey: Int32(wParam), lParam: lParam) ? 0 : nil

        case WM_MOUSEWHEEL:
            handleWheel(delta: Int32(SixRailWheelDelta(wParam)), horizontal: false)
            return 0

        case WM_MOUSEHWHEEL:
            handleWheel(delta: Int32(SixRailWheelDelta(wParam)), horizontal: true)
            return 0

        default:
            return nil
        }
    }
}

/// The `WNDPROC` itself — deliberately `nonisolated`: a C function pointer cannot carry actor
/// isolation, and the message it is handed cannot cross into `@MainActor` code on its own. Only
/// whether it was taken can, which is what `MainActor.assumeIsolated` hands back.
private nonisolated func railWindowProc(
    _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    if Int32(message) == WM_NCCREATE {
        if let hwnd, let params = SixRailCreateParams(lParam) {
            SixRailSetUserData(hwnd, params)
        }
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }

    guard let hwnd, let stored = SixRailGetUserData(hwnd) else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    let window = Unmanaged<RailWindow>.fromOpaque(stored).takeUnretainedValue()
    let handled = MainActor.assumeIsolated {
        window.handle(message: message, wParam: wParam, lParam: lParam)
    }
    return handled ?? DefWindowProcW(hwnd, message, wParam, lParam)
}
