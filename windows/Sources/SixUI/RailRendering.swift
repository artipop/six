import Foundation
import SixBrowser
import WinSDK

/// GDI painting for the rail, and the one piece of geometry `RailInput` borrows back: where a
/// column's close box sits, so a click can be tested against exactly what was drawn.
extension RailWindow {
    // MARK: Palette

    /// `RGB()` is a C macro, not a function — this is the arithmetic it expands to.
    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> COLORREF {
        COLORREF(r) | (COLORREF(g) << 8) | (COLORREF(b) << 16)
    }

    static let backgroundColor = rgb(24, 24, 27)
    static let cardBorderColor = rgb(63, 63, 70)
    static let focusedBorderColor = rgb(96, 140, 220)
    static let textColor = rgb(228, 228, 231)
    static let focusedTextColor = rgb(255, 255, 255)
    static let labelColor = rgb(161, 161, 170)

    /// A card is a title and a color, nothing else yet — so the color has to carry a column's whole
    /// identity: without it every unfocused card was the same grey rectangle, and there was no way
    /// to tell two open tabs apart short of clicking each one to see which title lit up. Picked by
    /// the tab's own id, not its position — a column keeps its color when the rail reorders it, the
    /// same way a real page would keep whatever the site painted.
    static let placeholderPalette: [COLORREF] = [
        rgb(64, 92, 155), rgb(155, 92, 64), rgb(88, 145, 88), rgb(140, 82, 150),
        rgb(150, 138, 68), rgb(70, 140, 138), rgb(150, 90, 110), rgb(96, 110, 150)
    ]

    // `Foundation.UUID` explicitly: `WinSDK` also brings in the C `UUID` typedef (`rpcdce.h`'s
    // `GUID` alias), and both are visible here, so the bare name is ambiguous.
    static func placeholderColor(for id: Foundation.UUID) -> COLORREF {
        placeholderPalette[Int(id.uuid.0) % placeholderPalette.count]
    }

    /// The little "×" in a card's corner, in the same coordinates the card itself is drawn in — so
    /// painting it and hit-testing a click against it can never drift apart.
    static func closeBoxRect(for card: RECT) -> RECT {
        let size: Int32 = 28
        let margin: Int32 = 8
        return RECT(
            left: card.right - size - margin, top: card.top + margin,
            right: card.right - margin, bottom: card.top + margin + size
        )
    }

    // MARK: Painting

    func paint() {
        guard let hwnd else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var client = RECT()
        GetClientRect(hwnd, &client)
        fill(hdc, client, with: Self.backgroundColor)
        SetBkMode(hdc, TRANSPARENT)

        drawWorkspaceLabel(hdc, in: client)
        for column in model.columns { draw(column, hdc: hdc) }
    }

    private func fill(_ hdc: HDC, _ rect: RECT, with color: COLORREF) {
        var rect = rect
        let brush = CreateSolidBrush(color)
        FillRect(hdc, &rect, brush)
        DeleteObject(brush)
    }

    private func drawWorkspaceLabel(_ hdc: HDC, in client: RECT) {
        var rect = RECT(left: 14, top: 8, right: client.right - 14, bottom: 30)
        SetTextColor(hdc, Self.labelColor)
        let text = "\(model.workspaceTitle)  ·  \(model.workspaceCount) workspace(s)"
        text.withCString(encodedAs: UTF16.self) { ptr in
            _ = DrawTextW(hdc, ptr, -1, &rect, UINT(DT_LEFT | DT_SINGLELINE))
        }
    }

    private func draw(_ column: RailModel.Column, hdc: HDC) {
        let card = RECT(
            left: Int32(column.frame.minX), top: Int32(column.frame.minY),
            right: Int32(column.frame.maxX), bottom: Int32(column.frame.maxY)
        )
        let fillColor = Self.placeholderColor(for: column.id)
        let borderColor = column.isFocused ? Self.focusedBorderColor : Self.cardBorderColor
        let brush = CreateSolidBrush(fillColor)
        let pen = CreatePen(Int32(PS_SOLID), column.isFocused ? 2 : 1, borderColor)
        let previousBrush = SelectObject(hdc, brush)
        let previousPen = SelectObject(hdc, pen)
        RoundRect(hdc, card.left, card.top, card.right, card.bottom, 14, 14)
        SelectObject(hdc, previousBrush)
        SelectObject(hdc, previousPen)
        DeleteObject(brush)
        DeleteObject(pen)

        SetTextColor(hdc, column.isFocused ? Self.focusedTextColor : Self.textColor)
        var titleRect = RECT(left: card.left + 16, top: card.top + 16, right: card.right - 44, bottom: card.top + 40)
        column.title.withCString(encodedAs: UTF16.self) { ptr in
            _ = DrawTextW(hdc, ptr, -1, &titleRect, UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
        }

        var closeRect = Self.closeBoxRect(for: card)
        "×".withCString(encodedAs: UTF16.self) { ptr in
            _ = DrawTextW(hdc, ptr, -1, &closeRect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        }
    }
}
