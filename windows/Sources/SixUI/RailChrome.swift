import CRailInterop
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// The top bar — the one piece of chrome this front draws, and the same band the Mac's `TopBar`
/// occupies: which profile you are in on the left, the focused page's address in the middle, and
/// everything about the strip rather than the page on the right.
///
/// It replaces the two stacked strips this front had before (a workspace caption above a bare
/// `EDIT` control), for the reason the Mac collapsed the same thing into one bar: a browser has one
/// row of chrome, and the address belongs in it.
///
/// Two rules hold this file together. **Everything is measured in logical pixels and multiplied by
/// `scale` at the point of use** — the window is Per-Monitor-V2 aware, so a constant written here
/// is physical pixels otherwise, and on this dev machine's 150% display that is a bar two thirds of
/// the height it should be. And **the layout is computed once, by `chromeLayout()`, and read by
/// both the painting and the hit-testing** — the same discipline `RailRendering.cardRect` keeps for
/// the cards, so a button cannot be drawn anywhere but where it is clickable.
extension RailWindow {
    // MARK: Metrics, in logical pixels

    enum Metric {
        /// The Mac's top bar is 40 points tall. So is this one.
        static let barHeight: Double = 40
        static let sidePadding: Double = 10
        static let itemGap: Double = 6

        static let chipHeight: Double = 26
        static let chipPadding: Double = 7
        static let profileDot: Double = 16

        static let buttonWidth: Double = 30
        static let buttonHeight: Double = 26

        /// The second line of the bar, which exists only while a translation has something to say.
        /// Shorter than the bar itself: it is a sentence and a progress bar, not a row of controls.
        static let bannerHeight: Double = 24
        static let bannerProgressHeight: Double = 3

        static let addressHeight: Double = 28
        /// A share of the window with a floor and a ceiling, the Mac's `TopBar.addressWidth`: a
        /// fixed field is a slot in the middle of nowhere on a wide display and crowds out the
        /// buttons on a narrow one.
        static let addressShare: Double = 0.42
        static let addressMinWidth: Double = 240
        static let addressMaxWidth: Double = 760
        static let addressRadius: Double = 8

        /// niri's workspace indicator, the Mac's `WorkspacePips`: one capsule per workspace, the
        /// one you are on longer and in the profile's colour.
        static let pipWidth: Double = 8
        static let pipCurrentWidth: Double = 20
        static let pipHeight: Double = 6
        static let pipGap: Double = 4

        /// A card's own title strip. `RailLiveView` insets the `WKView` below it, which is what
        /// keeps the close box clickable rather than covered by the page's child `HWND`.
        static let cardHeader: Double = 34
        static let cardRadius: Double = 10
        static let closeBox: Double = 22
    }

    /// Logical pixels to physical ones, at this window's current DPI.
    func px(_ logical: Double) -> Int32 { Int32((logical * scale).rounded()) }

    /// What the rail below the bar does not get. `NiriLayout`'s viewport is the rail's canvas
    /// alone; the chrome above it is this file's business, not the layout's.
    ///
    /// It is not a constant, because the translation banner is a second line of chrome that comes
    /// and goes. `RailLiveView.updateLiveView` notices when it changes and hands the layout its new
    /// canvas; everything else — the cards, the live view, the hit-testing — is measured from here
    /// already and follows for free.
    var topChromeHeight: Int32 { px(Metric.barHeight) + translationBannerHeight }

    /// The translation state of the column on screen, which is the only one the bar ever describes.
    var focusedTranslation: TabTranslation? {
        guard let focused = model.columns.first(where: \.isFocused) else { return nil }
        return translation[focused.id]
    }

    /// Zero unless there is something to say. "Done" is not one of those: the button says that.
    var translationBannerHeight: Int32 {
        (focusedTranslation?.saysSomething ?? false) ? px(Metric.bannerHeight) : 0
    }

    // MARK: Palette

    /// `RGB()` is a C macro, not a function — this is the arithmetic it expands to.
    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> COLORREF {
        COLORREF(r) | (COLORREF(g) << 8) | (COLORREF(b) << 16)
    }

    static let backgroundColor = rgb(24, 24, 27)
    static let barColor = rgb(32, 32, 36)
    static let barBorderColor = rgb(56, 56, 62)
    static let chipColor = rgb(52, 52, 58)
    /// A card that has a live page: the strip above the page and the border around it, and nothing
    /// else of the card is visible.
    static let cardChromeColor = rgb(38, 38, 43)
    static let addressFieldColor = rgb(46, 46, 52)
    static let addressBorderColor = rgb(72, 72, 80)
    static let cardBorderColor = rgb(63, 63, 70)
    static let focusedBorderColor = rgb(96, 140, 220)
    static let textColor = rgb(228, 228, 231)
    static let focusedTextColor = rgb(255, 255, 255)
    static let labelColor = rgb(161, 161, 170)
    /// Windows' own caption-button hover: a light wash on minimize and maximize, and the red that
    /// every Windows user aims at without reading the glyph.
    static let captionHoverColor = rgb(62, 62, 70)
    static let closeHoverColor = rgb(232, 17, 35)
    static let dimLabelColor = rgb(112, 112, 122)

    /// `#RRGGBB`, the way a `Profile` carries its colour, in `COLORREF`'s own byte order. Anything
    /// unparseable comes back as the focus blue rather than as black, which would read as a bug in
    /// the chip rather than as a bad hex string.
    static func color(hex: String) -> COLORREF {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return focusedBorderColor }
        return rgb(UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    // MARK: Fonts

    /// Segoe UI at three sizes, plus Windows' own icon face for the glyphs.
    ///
    /// GDI's default object is `SYSTEM_FONT` — a bitmap face from Windows 3.1 that neither scales
    /// nor antialiases — and that is what every string on this front used to be drawn in. These are
    /// created once per DPI (`refreshFonts`) rather than per paint: an `HFONT` is a kernel object,
    /// and a `WM_PAINT` that makes one leaks it as fast as the window repaints.
    ///
    /// `Segoe MDL2 Assets` is the icon face every Windows 10 ships — File Explorer's own chrome
    /// draws with it — so the glyphs below are as safe here as an SF Symbol is on the Mac.
    struct ChromeFonts {
        var ui: HFONT?
        var strong: HFONT?
        var small: HFONT?
        var glyph: HFONT?
        /// The window controls, which Windows draws smaller than anything else in a title bar.
        var caption: HFONT?

        static let uiFace = "Segoe UI"
        static let glyphFace = "Segoe MDL2 Assets"

        enum Glyph {
            static let back = "\u{E72B}"
            static let forward = "\u{E72A}"
            static let reload = "\u{E72C}"
            static let chevronUp = "\u{E70E}"
            static let chevronDown = "\u{E70D}"
            static let fullWidth = "\u{E740}"
            static let restoreWidth = "\u{E73F}"
            static let close = "\u{E711}"
            /// Segoe MDL2's globe, which is what Windows itself uses for anything about language.
            static let translate = "\u{E774}"
            // The window controls. These four are a set of their own in the icon font, drawn at
            // stroke widths meant for a title bar rather than for a toolbar.
            static let chromeMinimize = "\u{E921}"
            static let chromeMaximize = "\u{E922}"
            static let chromeRestore = "\u{E923}"
            static let chromeClose = "\u{E8BB}"
        }
    }

    /// Called once the window has an `HWND` to ask a DPI of, and again on `WM_DPICHANGED`; deletes
    /// what it replaces.
    func refreshFonts() {
        for font in [fonts.ui, fonts.strong, fonts.small, fonts.glyph, fonts.caption] where font != nil {
            DeleteObject(font)
        }
        fonts = ChromeFonts(
            ui: Self.makeFont(face: ChromeFonts.uiFace, size: 14, weight: FW_NORMAL, scale: scale),
            strong: Self.makeFont(face: ChromeFonts.uiFace, size: 13, weight: FW_SEMIBOLD, scale: scale),
            small: Self.makeFont(face: ChromeFonts.uiFace, size: 12, weight: FW_NORMAL, scale: scale),
            glyph: Self.makeFont(face: ChromeFonts.glyphFace, size: 12, weight: FW_NORMAL, scale: scale),
            caption: Self.makeFont(face: ChromeFonts.glyphFace, size: 10, weight: FW_NORMAL, scale: scale)
        )
        if let addressBarHwnd, let ui = fonts.ui {
            // The `EDIT` goes on drawing in whatever it was last told, so this is the half of a DPI
            // change the control cannot notice by itself. `lParam` 1 is "and redraw".
            SendMessageW(addressBarHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: ui))), 1)
        }
    }

    /// A negative height is character height rather than cell height — the size a person means when
    /// they say "14 point".
    private static func makeFont(face: String, size: Double, weight: Int32, scale: Double) -> HFONT? {
        face.withCString(encodedAs: UTF16.self) { name in
            CreateFontW(
                -Int32((size * scale).rounded()), 0, 0, 0, weight,
                0, 0, 0,
                DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH | FF_DONTCARE), name
            )
        }
    }

    // MARK: Where everything in the bar is

    /// Every rectangle the bar owns, in client coordinates, built in one pass so that painting and
    /// hit-testing cannot disagree about where a control is.
    struct ChromeLayout {
        var bar = RECT()
        var profileChip = RECT()
        var back = RECT()
        var forward = RECT()
        var reload = RECT()
        var addressPill = RECT()
        var workspaceUp = RECT()
        var workspacePips = RECT()
        var workspaceDown = RECT()
        var fullWidth = RECT()
        var translate = RECT()
        /// The second line, empty when the translation has nothing to say.
        var banner = RECT()
    }

    /// One pip's rectangle inside `workspacePips`, so that drawing them and clicking one cannot
    /// disagree about which is which.
    func pipRect(_ index: Int, in pips: RECT) -> RECT {
        let current = model.focusedWorkspaceIndex
        var left = pips.left
        for i in 0..<index {
            left += px(i == current ? Metric.pipCurrentWidth : Metric.pipWidth) + px(Metric.pipGap)
        }
        let width = px(index == current ? Metric.pipCurrentWidth : Metric.pipWidth)
        let height = px(Metric.pipHeight)
        let top = pips.top + (pips.bottom - pips.top - height) / 2
        return RECT(left: left, top: top, right: left + width, bottom: top + height)
    }

    /// As wide as the pips it has to hold: the stack of workspaces grows and shrinks while six runs.
    private func pipsWidth() -> Int32 {
        let count = model.workspaceCount
        guard count > 0 else { return 0 }
        let others = Int32(count - 1) * (px(Metric.pipWidth) + px(Metric.pipGap))
        return px(Metric.pipCurrentWidth) + others
    }

    func chromeLayout() -> ChromeLayout {
        guard let hwnd else { return ChromeLayout() }
        var client = RECT()
        GetClientRect(hwnd, &client)

        var layout = ChromeLayout()
        // The bar itself, and not the banner under it. `topChromeHeight` is the two of them
        // together — it is what the *rail* has to be pushed down by — and using it here put every
        // control in the bar half a banner too low the first time a translation ran.
        let barBottom = px(Metric.barHeight)
        layout.bar = RECT(left: 0, top: 0, right: client.right, bottom: barBottom)

        let pad = px(Metric.sidePadding)
        let gap = px(Metric.itemGap)
        /// Vertically centred in the bar, which is where every control in it sits.
        func centred(_ height: Double) -> (top: Int32, bottom: Int32) {
            let h = px(height)
            let top = (barBottom - h) / 2
            return (top, top + h)
        }

        let chip = centred(Metric.chipHeight)
        let chipWidth = px(Metric.chipPadding) * 2 + px(Metric.profileDot) + px(6)
            + measure(model.activeProfile.name, font: fonts.strong) + px(16)
        layout.profileChip = RECT(left: pad, top: chip.top, right: pad + chipWidth, bottom: chip.bottom)

        let button = centred(Metric.buttonHeight)
        let buttonWidth = px(Metric.buttonWidth)
        let navLeft = layout.profileChip.right + gap * 2
        layout.back = RECT(left: navLeft, top: button.top, right: navLeft + buttonWidth, bottom: button.bottom)
        layout.forward = RECT(left: layout.back.right, top: button.top,
                              right: layout.back.right + buttonWidth, bottom: button.bottom)
        layout.reload = RECT(left: layout.forward.right, top: button.top,
                             right: layout.forward.right + buttonWidth, bottom: button.bottom)

        // The right-hand cluster is laid out from the right edge inwards, so it keeps its place
        // whatever the middle of the bar does.
        // Inside the window controls, which own the right end of the bar now that the bar *is* the
        // title bar (`RailFrame`). Everything else in the cluster is measured from here.
        let rightEdge = client.right - captionButtonsWidth - pad
        layout.fullWidth = RECT(left: rightEdge - buttonWidth, top: button.top,
                                right: rightEdge, bottom: button.bottom)
        // ⌃ pips ⌄, the order the Mac's `WorkspaceStepper` puts them in.
        layout.workspaceDown = RECT(left: layout.fullWidth.left - gap - buttonWidth, top: button.top,
                                    right: layout.fullWidth.left - gap, bottom: button.bottom)
        let pipsWidth = pipsWidth()
        layout.workspacePips = RECT(left: layout.workspaceDown.left - pipsWidth, top: button.top,
                                    right: layout.workspaceDown.left, bottom: button.bottom)
        layout.workspaceUp = RECT(left: layout.workspacePips.left - buttonWidth, top: button.top,
                                  right: layout.workspacePips.left, bottom: button.bottom)
        // Beside the workspace controls rather than beside back and forward: it is about the page,
        // not about where you have been.
        layout.translate = RECT(left: layout.workspaceUp.left - gap - buttonWidth, top: button.top,
                                right: layout.workspaceUp.left - gap, bottom: button.bottom)

        if translationBannerHeight > 0 {
            layout.banner = RECT(left: 0, top: px(Metric.barHeight),
                                 right: client.right, bottom: topChromeHeight)
        }

        // No focused window, no address: the Mac drops the field (and the star with it) on an empty
        // workspace, because a field describing nothing is worse than a gap. An empty rect is how
        // the rest of this file says "not this frame".
        guard model.columns.contains(where: \.isFocused) else { return layout }

        // Centred in the window rather than in what is left over: the Mac's field sits between two
        // spacers, and a field that slides sideways as a profile name changes length reads as the
        // window twitching. It gives way only when the two clusters would otherwise reach it.
        let share = Double(client.right) / scale * Metric.addressShare
        let wanted = px(min(max(share, Metric.addressMinWidth), Metric.addressMaxWidth))
        let leftLimit = layout.reload.right + gap * 2
        let rightLimit = layout.translate.left - gap * 2
        let width = max(0, min(wanted, rightLimit - leftLimit))
        var left = (client.right - width) / 2
        left = min(max(left, leftLimit), max(leftLimit, rightLimit - width))
        let address = centred(Metric.addressHeight)
        layout.addressPill = RECT(left: left, top: address.top, right: left + width, bottom: address.bottom)
        return layout
    }

    /// Width of a string in a given font, for the one control whose size is its content's — the
    /// profile chip, which is as wide as the profile's name.
    func measure(_ text: String, font: HFONT?) -> Int32 {
        guard let hwnd, let hdc = GetDC(hwnd) else { return 0 }
        defer { _ = ReleaseDC(hwnd, hdc) }
        let previous = font.map { SelectObject(hdc, $0) }
        var size = SIZE()
        let units = Array(text.utf16)
        _ = units.withUnsafeBufferPointer { buffer in
            GetTextExtentPoint32W(hdc, buffer.baseAddress, Int32(buffer.count), &size)
        }
        if let previous { SelectObject(hdc, previous) }
        return size.cx
    }

    // MARK: Painting the bar

    func drawTopBar(_ hdc: HDC, layout: ChromeLayout) {
        fill(hdc, layout.bar, with: Self.barColor)
        fill(hdc, RECT(left: 0, top: layout.bar.bottom - 1, right: layout.bar.right, bottom: layout.bar.bottom),
             with: Self.barBorderColor)

        drawProfileChip(hdc, in: layout.profileChip)

        let live = focusedWebView
        drawGlyph(hdc, ChromeFonts.Glyph.back, in: layout.back, enabled: live?.canGoBack ?? false)
        drawGlyph(hdc, ChromeFonts.Glyph.forward, in: layout.forward, enabled: live?.canGoForward ?? false)
        drawGlyph(hdc, ChromeFonts.Glyph.reload, in: layout.reload, enabled: live != nil)

        drawAddressField(hdc, in: layout.addressPill)

        drawTranslateButton(hdc, in: layout.translate)
        drawGlyph(hdc, ChromeFonts.Glyph.chevronUp, in: layout.workspaceUp, enabled: model.canFocusWorkspace(-1))
        drawWorkspacePips(hdc, in: layout.workspacePips)
        drawGlyph(hdc, ChromeFonts.Glyph.chevronDown, in: layout.workspaceDown, enabled: model.canFocusWorkspace(1))
        drawGlyph(hdc, model.isFullWidth ? ChromeFonts.Glyph.restoreWidth : ChromeFonts.Glyph.fullWidth,
                  in: layout.fullWidth, enabled: true)

        drawTranslationBanner(hdc, in: layout.banner)
        drawCaptionButtons(hdc)
    }

    /// Where you are in the stack of workspaces: niri's own indicator, laid out horizontally, and
    /// the Mac's `WorkspacePips` down to the shapes — the current one longer and in the profile's
    /// colour, an empty one outlined rather than filled. Clicking one goes there.
    private func drawWorkspacePips(_ hdc: HDC, in rect: RECT) {
        let current = model.focusedWorkspaceIndex
        let accent = Self.color(hex: model.activeProfile.colorHex)
        for index in 0..<model.workspaceCount {
            let pip = pipRect(index, in: rect)
            let empty = model.isWorkspaceEmpty(at: index)
            let radius = (pip.bottom - pip.top) / 2
            roundedRect(hdc, pip, radius: radius,
                        fill: index == current ? accent : (empty ? Self.barColor : Self.chipColor),
                        border: index == current ? accent : Self.dimLabelColor, borderWidth: 1)
        }
    }

    /// The circle that stands for a profile everywhere on the Mac, with its initial in it, and the
    /// name beside it — a dropdown rather than a row of dots, for the reason `ProfileMenu.swift`
    /// gives: a row of coloured circles is fine for two profiles and unreadable for five.
    private func drawProfileChip(_ hdc: HDC, in rect: RECT) {
        let profile = model.activeProfile
        roundedRect(hdc, rect, radius: px(7), fill: Self.chipColor, border: Self.barBorderColor, borderWidth: 1)

        let dot = px(Metric.profileDot)
        let dotLeft = rect.left + px(Metric.chipPadding)
        let dotTop = rect.top + (rect.bottom - rect.top - dot) / 2
        let dotRect = RECT(left: dotLeft, top: dotTop, right: dotLeft + dot, bottom: dotTop + dot)
        let color = Self.color(hex: profile.colorHex)
        let brush = CreateSolidBrush(color)
        let pen = CreatePen(Int32(PS_SOLID), 1, color)
        let previousBrush = SelectObject(hdc, brush)
        let previousPen = SelectObject(hdc, pen)
        Ellipse(hdc, dotRect.left, dotRect.top, dotRect.right, dotRect.bottom)
        SelectObject(hdc, previousBrush)
        SelectObject(hdc, previousPen)
        DeleteObject(brush)
        DeleteObject(pen)

        drawText(hdc, String(profile.name.prefix(1)).uppercased(), in: dotRect, font: fonts.small,
                 color: Self.rgb(255, 255, 255), format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)

        let nameRect = RECT(left: dotRect.right + px(6), top: rect.top,
                            right: rect.right - px(15), bottom: rect.bottom)
        drawText(hdc, profile.name, in: nameRect, font: fonts.strong, color: Self.textColor,
                 format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
        let chevron = RECT(left: rect.right - px(16), top: rect.top, right: rect.right, bottom: rect.bottom)
        drawText(hdc, ChromeFonts.Glyph.chevronDown, in: chevron, font: fonts.glyph,
                 color: Self.dimLabelColor, format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }

    /// The pill behind the `EDIT` control. The control is inset into it and painted the same colour
    /// (`WM_CTLCOLOREDIT`), so what shows around it is this rounded rectangle's own edge — a field
    /// with rounded ends, out of a Win32 control that has no such thing.
    private func drawAddressField(_ hdc: HDC, in rect: RECT) {
        guard rect.right > rect.left else { return }
        let focused = addressBarHwnd != nil && GetFocus() == addressBarHwnd
        roundedRect(hdc, rect, radius: px(Metric.addressRadius), fill: Self.addressFieldColor,
                    border: focused ? Self.focusedBorderColor : Self.addressBorderColor,
                    borderWidth: focused ? 2 : 1)
    }

    // MARK: GDI helpers

    func fill(_ hdc: HDC, _ rect: RECT, with color: COLORREF) {
        var rect = rect
        let brush = CreateSolidBrush(color)
        FillRect(hdc, &rect, brush)
        DeleteObject(brush)
    }

    func roundedRect(_ hdc: HDC, _ rect: RECT, radius: Int32, fill: COLORREF, border: COLORREF, borderWidth: Int32) {
        let brush = CreateSolidBrush(fill)
        let pen = CreatePen(Int32(PS_SOLID), borderWidth, border)
        let previousBrush = SelectObject(hdc, brush)
        let previousPen = SelectObject(hdc, pen)
        RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2)
        SelectObject(hdc, previousBrush)
        SelectObject(hdc, previousPen)
        DeleteObject(brush)
        DeleteObject(pen)
    }

    func drawText(_ hdc: HDC, _ text: String, in rect: RECT, font: HFONT?, color: COLORREF, format: Int32) {
        var rect = rect
        let previous = font.map { SelectObject(hdc, $0) }
        SetTextColor(hdc, color)
        text.withCString(encodedAs: UTF16.self) { ptr in
            _ = DrawTextW(hdc, ptr, -1, &rect, UINT(format))
        }
        if let previous { SelectObject(hdc, previous) }
    }

    /// A button's glyph, greyed when the thing it does is not available. The state is drawn, not
    /// the control disabled — CLAUDE.md's note about a disabled item eating its key equivalent is
    /// the Mac's version of the same preference.
    func drawGlyph(_ hdc: HDC, _ glyph: String, in rect: RECT, enabled: Bool) {
        drawText(hdc, glyph, in: rect, font: fonts.glyph,
                 color: enabled ? Self.textColor : Self.dimLabelColor,
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }
}
