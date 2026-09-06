import CRailInterop
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
        wc.hCursor = LoadCursorW(nil, IDC_ARROW)
        wc.hbrBackground = nil

        let registered = Self.className.withCString(encodedAs: UTF16.self) { name -> ATOM in
            wc.lpszClassName = name
            return RegisterClassExW(&wc)
        }
        guard registered != 0 else { return false }

        let created = Self.className.withCString(encodedAs: UTF16.self) { classNamePtr in
            "six".withCString(encodedAs: UTF16.self) { titlePtr in
                CreateWindowExW(
                    0, classNamePtr, titlePtr, DWORD(WS_OVERLAPPEDWINDOW),
                    Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 1280, 800,
                    nil, nil, instance, Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }
        guard let created else { return false }
        hwnd = created
        return true
    }

    public func show() {
        guard let hwnd else { return }
        ShowWindow(hwnd, SW_SHOWDEFAULT)
        UpdateWindow(hwnd)
    }

    /// The classic `GetMessage`/`DispatchMessage` pump. Returns once `WM_QUIT` arrives, with the
    /// exit code it carried.
    public func run() -> Int32 {
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) > 0 {
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
            handleKeyDown(virtualKey: Int32(wParam), lParam: lParam)
            return 0

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
