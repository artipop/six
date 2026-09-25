import Foundation
import SixBrowser
import WinSDK

/// The overview (`⌥O`): every workspace of the profile on screen, stacked, zoomed out — the Mac's
/// `TilingStripView` with `layout.isOverview` on, drawn in GDI from the same numbers.
///
/// Nothing here is a page. The overview is a way of looking at the whole row, and a strip of live
/// `WKView`s scaled to a fifth of their size is neither sharp nor something WebKit's Windows port
/// can do (a child `HWND` has no transform), so every view is hidden while it is open and each card
/// shows the picture its page left (`StripThumbnails`) — which is also what the Mac draws there
/// (`ColumnPlaceholder(showsPicture:)`).
///
/// A click on a card goes to that window and closes the overview; a click anywhere else closes it
/// where it stood. `⌥O` and `Esc` close it too, and the wheel walks it without `Alt` — the Mac's
/// scroll monitor drops its modifier in the overview for the same reason: there is no page under
/// the pointer to give the gesture to.
extension StripWindow {
    func drawOverview(_ hdc: HDC, client: RECT) {
        let accent = Self.color(hex: model.activeProfile.colorHex)
        for row in model.overviewRows {
            let top = Int32(row.top) + topChromeHeight
            let label = RECT(left: Int32(row.left), top: top - px(24), right: client.right, bottom: top - px(4))
            drawText(hdc, row.title, in: label, font: fonts.strong,
                     color: row.isFocused ? Self.textColor : Self.dimLabelColor,
                     format: DT_LEFT | DT_BOTTOM | DT_SINGLELINE | DT_END_ELLIPSIS)
        }

        let header = max(px(16), Int32(Double(px(Metric.cardHeader)) * model.overviewScale))
        for card in model.overviewCards {
            let rect = cardRect(for: card.frame)
            guard rect.right > client.left, rect.left < client.right,
                  rect.bottom > topChromeHeight, rect.top < client.bottom else { continue }
            roundedRect(hdc, rect, radius: px(6), fill: Self.placeholderColor(for: card.id),
                        border: card.isFocused ? accent : Self.cardBorderColor,
                        borderWidth: card.isFocused ? 2 : 1)
            let body = RECT(left: rect.left + 1, top: rect.top + header, right: rect.right - 1, bottom: rect.bottom - 1)
            if let picture = thumbnail(for: card.id) { drawThumbnail(hdc, picture, into: body) }
            let title = RECT(left: rect.left + px(8), top: rect.top, right: rect.right - px(6), bottom: rect.top + header)
            drawText(hdc, card.title, in: title, font: fonts.small,
                     color: card.isFocused ? Self.focusedTextColor : Self.textColor,
                     format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
        }
    }

    /// The card under a point, topmost first — the same `cardRect` the painting used, so the two
    /// cannot disagree about where a card is.
    func overviewCard(atX x: Int, y: Int) -> StripModel.OverviewCard? {
        guard y >= Int(topChromeHeight) else { return nil }
        return model.overviewCards.last { cardRect(for: $0.frame).contains(x: x, y: y) }
    }

    /// Photographed on the way in, while the pages are still on screen to be photographed: the
    /// overview is the one place every picture is looked at.
    func toggleOverview() {
        if !model.isOverview { captureVisibleThumbnails() }
        model.toggleOverview()
        invalidate()
    }
}
