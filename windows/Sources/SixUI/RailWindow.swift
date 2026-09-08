import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// One Win32 window: the rail, drawn with GDI, and the input that drives it.
///
/// A `WNDPROC` is a plain C function pointer with no captures, so the instance it belongs to travels
/// through `GWLP_USERDATA` — set on `WM_NCCREATE`, read back on every message after. That
/// bookkeeping is `CRailInterop`'s; what arrives here is already a `RailWindow`.
@MainActor
public final class RailWindow {
    public private(set) var hwnd: HWND?
    let model = RailModel.shared

    /// See `RailInput.handleWheel` for why a notch is accumulated rather than acted on as it lands.
    var wheelRemainderY: Int32 = 0
    var wheelRemainderX: Int32 = 0

    /// `Foundation.UUID` explicitly: `WinSDK` also brings in the C `UUID` typedef (`rpcdce.h`'s
    /// `GUID` alias), so the bare name is ambiguous anywhere both are imported.
    var webViews: [Foundation.UUID: RailWebView] = [:]

    var addressBarHwnd: HWND?
    /// `EDIT`'s own `WNDPROC`, saved so the subclass can forward what it does not care about.
    var originalAddressBarProc: WNDPROC?
    /// Which column's URL the bar is showing — see `syncAddressBarIfNeeded` for why it is tracked.
    var addressBarShownTabID: Foundation.UUID?

    static let className = "SixRailWindow"

    public init() {}

    /// `false` means `RegisterClassExW` or `CreateWindowExW` failed; both log `GetLastError`.
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
                // `CW_USEDEFAULT` for the size too: a hard-coded 1280x800 is taller than this dev
                // machine's own display, which is CLAUDE.md's "sizes are fractions of the viewport".
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
        ensureAddressBar(instance: instance)
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
        // A SwiftPM executable links console-subsystem by default, so a console window opens
        // alongside the rail and takes the keyboard: clicks still land (they route by cursor
        // position) but no key reaches `WM_KEYDOWN`. Claiming both explicitly is the fix until the
        // target can link `/SUBSYSTEM:WINDOWS` — see Package.swift for why it does not yet.
        SetForegroundWindow(hwnd)
        SetFocus(hwnd)
    }

    public func run() -> Int32 {
        // `GetMessageW` imports as `Bool` here, not the tri-state `BOOL` — so `WM_QUIT` and an error
        // both read as `false` and end the loop the same way.
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

    /// `nil` is everything left to `DefWindowProcW`.
    func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_DESTROY:
            for view in webViews.values { view.destroy() }
            webViews.removeAll()
            PostQuitMessage(0)
            return 0

        case WM_ERASEBKGND:
            return 1 // WM_PAINT repaints the whole client area; nothing needs erasing first

        case WM_PAINT:
            // Before `paint()`, not inside it: moving a child `HWND` mid-`BeginPaint`/`EndPaint` is
            // not something to ask of a window that is already painting.
            updateLiveView()
            paint()
            return 0

        case WM_SIZE:
            let width = Int(SixRailLoWord(lParam))
            let height = Int(SixRailHiWord(lParam))
            // `NiriLayout`'s viewport is the rail's canvas alone; the chrome above it is
            // `RailRendering.cardRect`'s business, not the layout's.
            let railHeight = max(0, height - Int(Self.topChromeHeight))
            if model.updateViewport(CGSize(width: width, height: railHeight)) { invalidate() }
            layoutAddressBar()
            return 0

        case WM_LBUTTONDOWN:
            handleClick(x: Int(SixRailPointX(lParam)), y: Int(SixRailPointY(lParam)))
            return 0

        case WM_KEYDOWN:
            return handleKeyDown(virtualKey: Int32(wParam), lParam: lParam) ? 0 : nil

        // Holding Alt is what turns the other key into a *system* key on Windows, and every binding
        // this front answers is `⌥`-something — so this case is not optional. `handleKeyDown` says
        // why it only swallows what actually matched.
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

/// `nonisolated` because a C function pointer cannot carry actor isolation; `MainActor
/// .assumeIsolated` is what crosses back in.
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
