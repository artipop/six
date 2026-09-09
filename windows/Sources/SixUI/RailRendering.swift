import Foundation
import SixBrowser
import WinSDK

/// GDI painting for the rail, and the geometry `RailInput` and `RailLiveView` borrow back — so
/// painting, hit-testing and the live view can never drift apart on where a card actually is.
/// The bar above the rail is `RailChrome`'s; the palette, the fonts and the metrics live there too.
extension RailWindow {
    /// A card is a title and a colour until its page is live, so the colour carries a column's whole
    /// identity — every unfocused card was otherwise the same grey rectangle. Keyed by the tab's id
    /// rather than its position, so a column keeps its colour when the rail reorders it.
    static let placeholderPalette: [COLORREF] = [
        rgb(64, 92, 155), rgb(155, 92, 64), rgb(88, 145, 88), rgb(140, 82, 150),
        rgb(150, 138, 68), rgb(70, 140, 138), rgb(150, 90, 110), rgb(96, 110, 150)
    ]

    // `Foundation.UUID` explicitly: `WinSDK` also brings in the C `UUID` typedef (`rpcdce.h`'s
    // `GUID` alias), and both are visible here, so the bare name is ambiguous.
    static func placeholderColor(for id: Foundation.UUID) -> COLORREF {
        placeholderPalette[Int(id.uuid.0) % placeholderPalette.count]
    }

    /// A column's frame in real window coordinates. `NiriLayout` lays columns out from `y = 0` like
    /// every other front, so the chrome above the rail is added here, once, rather than baked into
    /// the layout — this is the only seam between where a column is and where it is drawn.
    func cardRect(for frame: CGRect) -> RECT {
        RECT(
            left: Int32(frame.minX), top: Int32(frame.minY) + topChromeHeight,
            right: Int32(frame.maxX), bottom: Int32(frame.maxY) + topChromeHeight
        )
    }

    func closeBoxRect(for card: RECT) -> RECT {
        let size = px(Metric.closeBox)
        let margin = px(6)
        return RECT(
            left: card.right - size - margin, top: card.top + margin,
            right: card.right - margin, bottom: card.top + margin + size
        )
    }

    /// Below the header: leaving that strip GDI's rather than the page's is what keeps the close
    /// box clickable instead of covered by a child `HWND`. Built on `cardRect`, the same conversion
    /// `draw` and `handleClick` use, so the three cannot disagree.
    func bodyRect(for frame: CGRect) -> RECT {
        let card = cardRect(for: frame)
        return RECT(left: card.left, top: card.top + px(Metric.cardHeader), right: card.right, bottom: card.bottom)
    }

    // MARK: Painting

    /// Painted into a memory bitmap and blitted once. The rail redraws whole on every focus change,
    /// every wheel notch and every resize, and a window that fills its background and then draws
    /// over it flickers visibly while any of those is held down.
    func paint() {
        guard let hwnd else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var client = RECT()
        GetClientRect(hwnd, &client)
        let width = client.right - client.left
        let height = client.bottom - client.top
        guard width > 0, height > 0, let memoryDC = CreateCompatibleDC(hdc),
              let bitmap = CreateCompatibleBitmap(hdc, width, height) else {
            drawEverything(hdc, client: client)
            return
        }
        let previousBitmap = SelectObject(memoryDC, bitmap)
        drawEverything(memoryDC, client: client)
        BitBlt(hdc, 0, 0, width, height, memoryDC, 0, 0, DWORD(SRCCOPY))
        SelectObject(memoryDC, previousBitmap)
        DeleteObject(bitmap)
        DeleteDC(memoryDC)
    }

    private func drawEverything(_ hdc: HDC, client: RECT) {
        fill(hdc, client, with: Self.backgroundColor)
        SetBkMode(hdc, TRANSPARENT)
        let columns = model.columns
        if columns.isEmpty {
            drawEmptyRailHint(hdc, client: client)
        } else {
            for column in columns { draw(column, hdc: hdc) }
        }
        drawTopBar(hdc, layout: chromeLayout())
    }

    /// What an empty workspace says, and the Mac's `EmptyWorkspaceHint` says it too: an empty rail
    /// with nothing on it reads as a browser that has stopped working. Switching to a profile that
    /// has never been used is the common way to get here, so it arrives on the first profile switch
    /// rather than in some corner.
    ///
    /// The whole background opens a window, so this is a label on something already clickable rather
    /// than a control of its own — which is why it is drawn and not a child `HWND`.
    private func drawEmptyRailHint(_ hdc: HDC, client: RECT) {
        let width = px(200)
        let height = px(38)
        let left = (client.right - width) / 2
        let top = topChromeHeight + (client.bottom - topChromeHeight - height) / 2 - px(12)
        let button = RECT(left: left, top: top, right: left + width, bottom: top + height)
        roundedRect(hdc, button, radius: px(8), fill: Self.chipColor,
                    border: Self.cardBorderColor, borderWidth: 1)
        drawText(hdc, "New window", in: button, font: fonts.strong, color: Self.textColor,
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
        let caption = RECT(left: client.left, top: button.bottom + px(8),
                           right: client.right, bottom: button.bottom + px(30))
        drawText(hdc, "click anywhere, or Ctrl+T", in: caption, font: fonts.small,
                 color: Self.dimLabelColor, format: DT_CENTER | DT_TOP | DT_SINGLELINE)
    }

    private func draw(_ column: RailModel.Column, hdc: HDC) {
        let card = cardRect(for: column.frame)
        // A card with a page in it is chrome around that page — the header strip and the border are
        // all of it that shows, because the `WKView` covers the rest. The identity colour is for the
        // card that has no page yet, where it is the only thing telling one column from another.
        let live = webViews[column.id] != nil
        // The focus ring is the profile's colour, the way the Mac's window border is `accent`.
        let accent = Self.color(hex: model.activeProfile.colorHex)
        roundedRect(hdc, card, radius: px(Metric.cardRadius),
                    fill: live ? Self.cardChromeColor : Self.placeholderColor(for: column.id),
                    border: column.isFocused ? accent : Self.cardBorderColor,
                    borderWidth: column.isFocused ? 2 : 1)

        let titleRect = RECT(
            left: card.left + px(12), top: card.top,
            right: closeBoxRect(for: card).left - px(6), bottom: card.top + px(Metric.cardHeader)
        )
        drawText(hdc, column.title, in: titleRect, font: fonts.strong,
                 color: column.isFocused ? Self.focusedTextColor : Self.textColor,
                 format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)

        drawGlyph(hdc, ChromeFonts.Glyph.close, in: closeBoxRect(for: card), enabled: true)
    }
}
