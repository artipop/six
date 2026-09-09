import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// The window's own frame, taken over so that the top bar *is* the title bar — the Mac's
/// arrangement, where the profile, the address and the buttons sit on the same line as the window
/// controls, and there is no second strip above them saying the name of the thing you are looking
/// at.
///
/// Windows gives no switch for this. The caption is non-client area, drawn by the system, and the
/// only way into it is to tell the system the client area covers it (`WM_NCCALCSIZE`) and then
/// answer for everything the caption used to do: where the window can be dragged, where it can be
/// resized, and the three buttons on the right, which vanish along with the caption. That is what
/// this file is, and it is the same shape every browser on Windows uses.
///
/// **The sides and the bottom are left alone on purpose.** `WM_NCCALCSIZE` here reclaims only the
/// top edge, so the resize borders on the other three sides are still the system's and
/// `DefWindowProcW` still answers `HTLEFT`/`HTBOTTOMRIGHT`/… for them. Taking the whole frame means
/// reimplementing all of that, and the part worth having is only the top.
extension RailWindow {
    enum CaptionButton: Equatable {
        case minimize, maximize, close
    }

    /// Windows' own caption buttons are 46 logical pixels wide. Matching that is not deference for
    /// its own sake: this is the one control on the window a person aims at without looking.
    static let captionButtonWidth: Double = 46

    var isMaximized: Bool {
        guard let hwnd else { return false }
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        guard GetWindowPlacement(hwnd, &placement) else { return false }
        return Int32(placement.showCmd) == SW_SHOWMAXIMIZED
    }

    /// How far a maximized window hangs off every edge of the monitor. Windows sizes a maximized
    /// window larger than the work area by exactly this much and relies on the frame to swallow it;
    /// a window with no top frame left must put it back by hand, or the first row of pixels of the
    /// bar is off the top of the screen.
    var frameThickness: Int32 {
        guard let hwnd else { return 0 }
        let dpi = GetDpiForWindow(hwnd)
        return GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
    }

    /// The strip along the top edge that still resizes rather than drags. The system frame is gone
    /// here, so this is drawn from nothing: a few pixels, the same few the system would have given.
    private var topResizeBorder: Int32 { max(px(4), frameThickness) }

    // MARK: The frame

    /// `WM_NCCALCSIZE`. Let the default do the whole calculation, then give the top back.
    ///
    /// The order matters: `DefWindowProcW` is what knows how thick this monitor's borders are at
    /// this DPI, and asking it first means the sides and bottom keep exactly the frame they would
    /// have had. Only `top` is overwritten — with the original, so the client area starts at the
    /// window's own top edge, and with the overhang added back when maximized.
    func handleNCCalcSize(wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        guard wParam != 0, let hwnd,
              let raw = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(lParam)))
        else { return nil }
        let params = raw.assumingMemoryBound(to: NCCALCSIZE_PARAMS.self)
        let requestedTop = params.pointee.rgrc.0.top
        _ = DefWindowProcW(hwnd, UINT(WM_NCCALCSIZE), wParam, lParam)
        params.pointee.rgrc.0.top = requestedTop + (isMaximized ? frameThickness : 0)
        return 0
    }

    /// `WM_NCHITTEST`. What the caption used to answer, answered here.
    ///
    /// `nil` hands the point back to `DefWindowProcW`, which is the right answer for the three edges
    /// that still have a system frame. Everything else is decided in client coordinates, in the same
    /// order a person would read it: the resize edge first, then the buttons, then whether the point
    /// is on a control of ours — and if it is not, the bar is somewhere to pick the window up by.
    func handleNCHitTest(screenX: Int32, screenY: Int32) -> LRESULT? {
        guard let hwnd else { return nil }
        var point = POINT(x: screenX, y: screenY)
        ScreenToClient(hwnd, &point)

        var client = RECT()
        GetClientRect(hwnd, &client)
        guard point.y >= 0, point.y < topChromeHeight, point.x >= 0, point.x < client.right else { return nil }

        if !isMaximized, point.y < topResizeBorder {
            // The corners keep their diagonal cursors: a top edge that only resizes vertically is a
            // window whose top corners have quietly stopped working.
            let corner = px(16)
            if point.x < corner { return LRESULT(HTTOPLEFT) }
            if point.x >= client.right - corner { return LRESULT(HTTOPRIGHT) }
            return LRESULT(HTTOP)
        }
        if let button = captionButton(atX: point.x, y: point.y) {
            switch button {
            case .minimize: return LRESULT(HTMINBUTTON)
            case .maximize: return LRESULT(HTMAXBUTTON)
            case .close: return LRESULT(HTCLOSE)
            }
        }
        if chromeAction(x: Int(point.x), y: Int(point.y)) != nil { return LRESULT(HTCLIENT) }
        return LRESULT(HTCAPTION)
    }

    // MARK: The buttons

    /// Right to left: close, maximize, minimize — the order Windows puts them in, which is the
    /// opposite of the Mac's and is not something to be clever about.
    func captionButtonRects() -> [(CaptionButton, RECT)] {
        guard let hwnd else { return [] }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let width = px(Self.captionButtonWidth)
        var right = client.right
        var rects: [(CaptionButton, RECT)] = []
        for button in [CaptionButton.close, .maximize, .minimize] {
            rects.append((button, RECT(left: right - width, top: 0, right: right, bottom: topChromeHeight)))
            right -= width
        }
        return rects
    }

    /// The width the rest of the bar must keep clear of.
    var captionButtonsWidth: Int32 { px(Self.captionButtonWidth) * 3 }

    func captionButton(atX x: Int32, y: Int32) -> CaptionButton? {
        captionButtonRects().first { $0.1.contains(x: Int(x), y: Int(y)) }?.0
    }

    /// Painted by us, because the system stopped painting them the moment the client area covered
    /// the caption. The hover colours are Windows' own: a light wash on the two on the left, and the
    /// red on close that every Windows user aims at without reading.
    func drawCaptionButtons(_ hdc: HDC) {
        for (button, rect) in captionButtonRects() {
            let hovered = hoveredCaptionButton == button
            if hovered {
                fill(hdc, rect, with: button == .close ? Self.closeHoverColor : Self.captionHoverColor)
            }
            let glyph: String
            switch button {
            case .minimize: glyph = ChromeFonts.Glyph.chromeMinimize
            case .maximize: glyph = isMaximized ? ChromeFonts.Glyph.chromeRestore : ChromeFonts.Glyph.chromeMaximize
            case .close: glyph = ChromeFonts.Glyph.chromeClose
            }
            drawText(hdc, glyph, in: rect, font: fonts.caption,
                     color: hovered && button == .close ? Self.rgb(255, 255, 255) : Self.textColor,
                     format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
        }
    }

    /// A button under the pointer is a button that has to look like one. The hover arrives as a
    /// *non-client* message, because `handleNCHitTest` said these three points are not client area.
    func handleNCMouseMove(hitTest: WPARAM) {
        let button: CaptionButton?
        switch Int32(hitTest) {
        case HTMINBUTTON: button = .minimize
        case HTMAXBUTTON: button = .maximize
        case HTCLOSE: button = .close
        default: button = nil
        }
        guard button != hoveredCaptionButton else { return }
        hoveredCaptionButton = button
        // Ask to be told when the pointer leaves, or a button that was hovered as the pointer left
        // the window stays lit until something else repaints.
        if button != nil, let hwnd {
            var track = TRACKMOUSEEVENT()
            track.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
            track.dwFlags = DWORD(TME_LEAVE | TME_NONCLIENT)
            track.hwndTrack = hwnd
            _ = TrackMouseEvent(&track)
        }
        invalidate()
    }

    func clearCaptionHover() {
        guard hoveredCaptionButton != nil else { return }
        hoveredCaptionButton = nil
        invalidate()
    }

    /// `DefWindowProcW` does nothing useful with `HTMINBUTTON` and friends on a window whose caption
    /// it no longer owns, so the press and the release are both ours. Acting on the *release*, and
    /// only if it lands on the button the press did, is what makes a mis-aimed click recoverable by
    /// sliding off — which is how every button on this platform behaves.
    func handleNCButtonDown(hitTest: WPARAM) -> Bool {
        switch Int32(hitTest) {
        case HTMINBUTTON: pressedCaptionButton = .minimize
        case HTMAXBUTTON: pressedCaptionButton = .maximize
        case HTCLOSE: pressedCaptionButton = .close
        default: return false
        }
        return true
    }

    func handleNCButtonUp(hitTest: WPARAM) -> Bool {
        guard let pressed = pressedCaptionButton, let hwnd else { return false }
        pressedCaptionButton = nil
        guard captionButton(from: hitTest) == pressed else { return true }
        switch pressed {
        case .minimize: ShowWindow(hwnd, SW_MINIMIZE)
        case .maximize: ShowWindow(hwnd, isMaximized ? SW_RESTORE : SW_MAXIMIZE)
        case .close: PostMessageW(hwnd, UINT(WM_CLOSE), 0, 0)
        }
        return true
    }

    private func captionButton(from hitTest: WPARAM) -> CaptionButton? {
        switch Int32(hitTest) {
        case HTMINBUTTON: return .minimize
        case HTMAXBUTTON: return .maximize
        case HTCLOSE: return .close
        default: return nil
        }
    }
}
