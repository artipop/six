import Foundation
import SixBrowser
import WinSDK

/// What a site is asking for, drawn where the answer belongs: in the column that asked, under its
/// own title — the Mac's `PermissionBar` and the Linux front's bar under a column's heading.
///
/// A bar rather than a dialog, and for the reason the Mac gives: a dialog belongs to the app, and
/// one column of twenty wanting the camera is no reason to stop the other nineteen. It pushes the
/// page down (`bodyRect(for:)`) rather than covering it, so its buttons are GDI's and not something
/// drawn under a child `HWND` that would take their clicks.
///
/// The page is suspended inside `getUserMedia()` for exactly as long as this is up.
extension RailWindow {
    struct PermissionBarLayout {
        var bar = RECT()
        var text = RECT()
        var block = RECT()
        var allow = RECT()
    }

    static let permissionBarHeight: Double = 38

    /// One function for painting and hit-testing, the discipline `chromeLayout()` keeps for the bar.
    func permissionBarLayout(for card: RECT) -> PermissionBarLayout {
        var layout = PermissionBarLayout()
        let top = card.top + px(Metric.cardHeader)
        layout.bar = RECT(left: card.left + 1, top: top, right: card.right - 1, bottom: top + px(Self.permissionBarHeight))
        let buttonHeight = px(26)
        let buttonTop = top + (layout.bar.bottom - top - buttonHeight) / 2
        let width = px(72)
        layout.allow = RECT(left: layout.bar.right - px(10) - width, top: buttonTop,
                            right: layout.bar.right - px(10), bottom: buttonTop + buttonHeight)
        layout.block = RECT(left: layout.allow.left - px(6) - width, top: buttonTop,
                            right: layout.allow.left - px(6), bottom: buttonTop + buttonHeight)
        layout.text = RECT(left: layout.bar.left + px(12), top: top,
                           right: layout.block.left - px(10), bottom: layout.bar.bottom)
        return layout
    }

    func drawPermissionBar(_ hdc: HDC, _ question: RailModel.PermissionQuestion, in card: RECT) {
        let layout = permissionBarLayout(for: card)
        fill(hdc, layout.bar, with: Self.barColor)
        fill(hdc, RECT(left: layout.bar.left, top: layout.bar.bottom - 1, right: layout.bar.right, bottom: layout.bar.bottom),
             with: Self.barBorderColor)
        drawText(hdc, question.prompt, in: layout.text,
                 font: fonts.ui, color: Self.textColor,
                 format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
        roundedRect(hdc, layout.block, radius: px(6), fill: Self.chipColor, border: Self.barBorderColor, borderWidth: 1)
        drawText(hdc, "Block", in: layout.block, font: fonts.strong, color: Self.textColor,
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
        let accent = Self.color(hex: model.activeProfile.colorHex)
        roundedRect(hdc, layout.allow, radius: px(6), fill: accent, border: accent, borderWidth: 1)
        drawText(hdc, "Allow", in: layout.allow, font: fonts.strong, color: Self.rgb(255, 255, 255),
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }

    /// `true` if the click was the bar's — answered, or simply landed on it and so on nothing else.
    func handlePermissionClick(_ column: RailModel.Column, card: RECT, x: Int, y: Int) -> Bool {
        guard column.permission != nil else { return false }
        let layout = permissionBarLayout(for: card)
        guard layout.bar.contains(x: x, y: y) else { return false }
        if layout.allow.contains(x: x, y: y) {
            model.answerPermission(true, for: column.id)
        } else if layout.block.contains(x: x, y: y) {
            model.answerPermission(false, for: column.id)
        }
        invalidate()
        return true
    }
}
