import CRailInterop
import Foundation
import SixBrowser
@testable import SixCore
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

    /// This window's DPI as a multiplier on the chrome's logical pixels — 1.5 on this dev machine's
    /// display. Everything `RailChrome` measures is multiplied by it; the rail itself is laid out in
    /// real pixels by `NiriLayout` and needs no such conversion, because its columns are fractions of
    /// the viewport rather than constants.
    var scale: Double = 1
    var fonts = ChromeFonts()

    /// `Foundation.UUID` explicitly: `WinSDK` also brings in the C `UUID` typedef (`rpcdce.h`'s
    /// `GUID` alias), so the bare name is ambiguous anywhere both are imported.
    var webViews: [Foundation.UUID: RailWebView] = [:]

    /// Translating the page you are reading. Made on first use — it opens a web process of its own
    /// for the engine, and a reader who never translates anything should never pay for one.
    lazy var translation = RailTranslation { [weak self] in self?.invalidate() }
    /// What `topChromeHeight` was when the rail's viewport was last computed. The bar grows a second
    /// line while a translation is running, and the rail below it has to be told.
    var lastChromeHeight: Int32 = 0

    var addressBarHwnd: HWND?
    /// `EDIT`'s own `WNDPROC`, saved so the subclass can forward what it does not care about.
    var originalAddressBarProc: WNDPROC?
    /// Which column's URL the bar is showing, and what it was last set to — see
    /// `syncAddressBarIfNeeded` for why both are tracked.
    var addressBarShownTabID: Foundation.UUID?
    var addressBarShownText: String?
    /// Where the `EDIT` was last put, so that the repaint-driven `layoutAddressBar` moves it only
    /// when it has actually moved. `nil` means it is hidden — there is no focused window.
    var addressBarFrame: RECT?
    /// The window control under the pointer, and the one a press landed on — the frame is ours now
    /// (`RailFrame`), so their hover and their press are ours to remember.
    var hoveredCaptionButton: CaptionButton?
    var pressedCaptionButton: CaptionButton?
    /// The live view's frame as `traceActualFrame` last reported it, so that trace says something
    /// only when it has something to say.
    var lastTracedFrame: [Int32] = []
    /// Back and forward as they were at the last poll — see `refreshLivePageState`, which repaints
    /// only when the page has actually changed one of the things the chrome draws.
    var lastNavigationState: [Bool] = [false, false]
    /// The `EDIT`'s background, answered to `WM_CTLCOLOREDIT`. Kept rather than made per message:
    /// that message arrives on every repaint of the control.
    var addressFieldBrush: HBRUSH?

    static let className = "SixRailWindow"
    /// Four times a second, which is fast enough that a title never looks stuck and slow enough to
    /// cost nothing.
    static let pageStateTimer: UINT_PTR = 1

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
                // `WS_CLIPCHILDREN` so the rail's own painting stops at the address field and at the
                // live page — without it the parent paints over both and they flicker back.
                CreateWindowExW(
                    0, classNamePtr, titlePtr, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
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
        updateScale()
        // Nothing has asked for a frame calculation yet, and `WM_NCCALCSIZE` is where this window
        // takes its title bar over (`RailFrame`). Without `SWP_FRAMECHANGED` the caption stays until
        // the first resize, and the bar spends that time drawn underneath it.
        SetWindowPos(created, nil, 0, 0, 0, 0,
                     UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        ensureAddressBar(instance: instance)
        SetTimer(created, Self.pageStateTimer, 400, nil)
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[six] window created, hwnd=\(String(describing: created)) scale=\(scale)\n".utf8))
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

    /// The rail's keys and its ⌥-scroll, taken out of the queue before the window they were aimed at
    /// ever sees them — which is the only place they can be taken, because the window they are aimed
    /// at is usually WebKit's.
    ///
    /// This is the Mac's `KeyRouter` in Win32 terms, and it exists for the same reason CLAUDE.md
    /// gives there: a page that has been clicked into holds the keyboard, and a shortcut that stops
    /// working the moment you use the page is not a shortcut. Before this, every rail binding worked
    /// only while the chrome had focus — a `WM_KEYDOWN` sent to the `WKView`'s own `HWND` never
    /// reaches this window's procedure at all.
    ///
    /// `true` swallows the message. Only what actually matched is swallowed: `⌥F4`, `⌥Space`, the
    /// page's own keys and everything typed into the address bar go on being somebody else's.
    func route(_ message: MSG) -> Bool {
        guard let hwnd, let target = message.hwnd,
              target == hwnd || IsChild(hwnd, target) else { return false }
        // The address field is a text field: while it has the keys, it has all of them. Enter and
        // Escape are its subclass procedure's business (`AddressBar`), not the rail's.
        if target == addressBarHwnd { return false }

        switch Int32(message.message) {
        case WM_KEYDOWN, WM_SYSKEYDOWN:
            let handled = handleChromeKey(virtualKey: Int32(message.wParam), lParam: message.lParam)
                || handleKeyDown(virtualKey: Int32(message.wParam), lParam: message.lParam)
            // The Mac's `SIX_UI_DEBUG=1` prints a line per key press saying where it landed and who
            // took it; this is that line. It is the only way to tell "the binding did nothing" from
            // "the key never arrived", which is the question every keyboard bug here starts with.
            if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
                let onPage = target != hwnd
                let trace = "[six] key vk=\(message.wParam) scan=\(SixRailScanCode(message.lParam)) " +
                    "ctrl=\(SixRailKeyDown(Int32(VK_CONTROL))) alt=\(SixRailKeyDown(Int32(VK_MENU))) " +
                    "shift=\(SixRailKeyDown(Int32(VK_SHIFT))) on=\(onPage ? "page" : "rail") " +
                    "taken=\(handled)\n"
                FileHandle.standardError.write(Data(trace.utf8))
            }
            return handled
        case WM_MOUSEWHEEL:
            guard SixRailKeyDown(Int32(VK_MENU)) != 0 else { return false }
            handleWheel(delta: Int32(SixRailWheelDelta(message.wParam)), horizontal: false)
            return true
        case WM_MOUSEHWHEEL:
            guard SixRailKeyDown(Int32(VK_MENU)) != 0 else { return false }
            handleWheel(delta: Int32(SixRailWheelDelta(message.wParam)), horizontal: true)
            return true
        default:
            return false
        }
    }

    func invalidate() {
        guard let hwnd else { return }
        InvalidateRect(hwnd, nil, false)
    }

    /// The chrome's scale, and the fonts made for it. Called at creation and on every
    /// `WM_DPICHANGED` — dragging the window to a display at another scale is the case this exists
    /// for, and the one that goes unnoticed until someone has two monitors.
    func updateScale() {
        guard let hwnd else { return }
        let dpi = GetDpiForWindow(hwnd)
        scale = dpi > 0 ? Double(dpi) / 96.0 : 1.0
        refreshFonts()
    }

    /// The window title says what you are reading, the way the Mac's `.navigationTitle` does.
    func updateWindowTitle() {
        guard let hwnd else { return }
        let focused = model.columns.first(where: \.isFocused)
        let title = focused.map { $0.title.isEmpty ? "six" : "\($0.title) — six" } ?? "six"
        _ = title.withCString(encodedAs: UTF16.self) { SetWindowTextW(hwnd, $0) }
    }

    /// The `WKView` of the focused column, if it has one — what the bar's back, forward and reload
    /// buttons act on, and what tells them whether they can.
    var focusedWebView: RailWebView? {
        guard let focused = model.columns.first(where: \.isFocused) else { return nil }
        return webViews[focused.id]
    }

    /// `nil` is everything left to `DefWindowProcW`.
    func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_DESTROY:
            if let hwnd { KillTimer(hwnd, Self.pageStateTimer) }
            for view in webViews.values { view.destroy() }
            webViews.removeAll()
            if let addressFieldBrush { DeleteObject(addressFieldBrush) }
            PostQuitMessage(0)
            return 0

        case WM_TIMER where wParam == Self.pageStateTimer:
            refreshLivePageState()
            return 0

        // MARK: The frame (RailFrame)

        case WM_NCCALCSIZE:
            return handleNCCalcSize(wParam: wParam, lParam: lParam)

        case WM_NCHITTEST:
            return handleNCHitTest(screenX: Int32(SixRailPointX(lParam)), screenY: Int32(SixRailPointY(lParam)))

        case WM_NCMOUSEMOVE:
            handleNCMouseMove(hitTest: wParam)
            return nil // and on to `DefWindowProcW`, which still owns the resize edges

        case WM_NCMOUSELEAVE, WM_MOUSEMOVE:
            clearCaptionHover()
            return nil

        case WM_NCLBUTTONDOWN:
            return handleNCButtonDown(hitTest: wParam) ? 0 : nil

        case WM_NCLBUTTONUP:
            return handleNCButtonUp(hitTest: wParam) ? 0 : nil

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
            // `NiriLayout`'s viewport is the rail's canvas alone; the bar above it is
            // `RailChrome`'s business, not the layout's.
            let railHeight = max(0, height - Int(topChromeHeight))
            _ = model.updateViewport(CGSize(width: width, height: railHeight))
            layoutAddressBar()
            // Unconditionally: a maximize changes no viewport the layout cares about on the way back
            // from full screen, and leaves the wrong glyph on the middle window control if nothing
            // repaints.
            invalidate()
            return 0

        // Dragged to a display at another scale. Windows hands over the rectangle the window should
        // take there; everything drawn in it is then re-measured against the new DPI.
        case WM_DPICHANGED:
            updateScale()
            if let suggested = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(lParam)))?
                .assumingMemoryBound(to: RECT.self).pointee, let hwnd {
                SetWindowPos(hwnd, nil, suggested.left, suggested.top,
                             suggested.right - suggested.left, suggested.bottom - suggested.top,
                             UINT(SWP_NOZORDER | SWP_NOACTIVATE))
            }
            layoutAddressBar()
            invalidate()
            return 0

        // The address field's colours. A Win32 `EDIT` paints its own background, and this is the one
        // message that gets a say in what with — the rest of the field's look is the pill
        // `RailChrome.drawAddressField` draws behind it.
        case WM_CTLCOLOREDIT:
            guard let hdc = UnsafeMutableRawPointer(bitPattern: UInt(wParam))?
                .assumingMemoryBound(to: HDC__.self) else { return nil }
            if addressFieldBrush == nil { addressFieldBrush = CreateSolidBrush(Self.addressFieldColor) }
            SetTextColor(hdc, Self.textColor)
            SetBkColor(hdc, Self.addressFieldColor)
            guard let addressFieldBrush else { return nil }
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(addressFieldBrush)))

        case WM_LBUTTONDOWN:
            handleClick(x: Int(SixRailPointX(lParam)), y: Int(SixRailPointY(lParam)))
            return 0

        // A pointing hand over anything in the bar that answers a click, the one cursor change this
        // front makes; everywhere else keeps the arrow the window class was registered with.
        case WM_SETCURSOR:
            guard let hwnd, Int32(SixRailLoWord(lParam)) == HTCLIENT else { return nil }
            var point = POINT()
            GetCursorPos(&point)
            ScreenToClient(hwnd, &point)
            guard chromeAction(x: Int(point.x), y: Int(point.y)) != nil else { return nil }
            SetCursor(SixRailHandCursor())
            return 1

        // Keys normally arrive through `route`, which takes them out of the queue before this
        // window's procedure is reached; these two cases catch the ones that never go through a
        // queue at all — a `SendMessageW` from another process, which is how this front has been
        // driven from a script more than once (docs/windows.md).
        case WM_KEYDOWN:
            if handleChromeKey(virtualKey: Int32(wParam), lParam: lParam) { return 0 }
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
