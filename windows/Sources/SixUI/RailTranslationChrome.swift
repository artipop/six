import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// What translation looks like in the top bar: one button, and a line under it while there is
/// something to say.
///
/// Split from `RailChrome` because that file is already the whole bar, and because these two draw
/// from a different source — everything else in the bar is the rail's state, and this is the page's.
/// The metrics, the palette and the GDI helpers are still `RailChrome`'s.
extension RailWindow {
    /// The one colour this front did not already have. Windows' own "attention" amber rather than a
    /// red: a page that could not be translated is not an error, it is a thing that did not happen.
    static let warningColor = rgb(226, 168, 76)

    /// A globe, and its colour says what state the page is in.
    ///
    /// Four states and no text, which is the most a 30-pixel button can carry: nothing to translate
    /// (dim), a page in another language (bright), translated or working (the profile's colour), and
    /// something to say about why not (amber). The sentence behind the last two is in the banner.
    func drawTranslateButton(_ hdc: HDC, in rect: RECT) {
        let state = focusedTranslation
        let accent = Self.color(hex: model.activeProfile.colorHex)
        let color: COLORREF
        switch state?.phase {
        case .failed:
            color = Self.warningColor
        case .downloading, .working:
            color = accent
        case .done:
            // Showing the original is still a translated page, and the button is what puts it back.
            color = state?.showsOriginal == true ? Self.textColor : accent
        case .offered:
            color = Self.textColor
        case nil:
            color = Self.dimLabelColor
        }
        drawText(hdc, ChromeFonts.Glyph.translate, in: rect, font: fonts.glyph, color: color,
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }

    /// The second line of the bar. Present only while the translation is doing something or has
    /// failed — a finished translation says so with the button's colour and takes its line back.
    ///
    /// It is a real line of chrome and not an overlay: `topChromeHeight` counts it, so the rail
    /// below moves down by exactly its height and no page is ever drawn under it.
    func drawTranslationBanner(_ hdc: HDC, in rect: RECT) {
        guard rect.bottom > rect.top, let state = focusedTranslation else { return }
        fill(hdc, rect, with: Self.barColor)
        fill(hdc, RECT(left: rect.left, top: rect.bottom - 1, right: rect.right, bottom: rect.bottom),
             with: Self.barBorderColor)

        let accent = Self.color(hex: model.activeProfile.colorHex)
        var message = ""
        var color = Self.labelColor
        switch state.phase {
        case .downloading:
            // No percentage exists to show — see `PageTranslating.isFetchingLanguages` — and the
            // size is the number that actually matters to someone deciding whether to wait.
            message = "Downloading the language for this page, about 35 MB, once"
        case .working(let done, let total):
            message = total > 0 ? "Translating \(done) of \(total)" : "Translating"
        case .failed(let why):
            message = why
            color = Self.warningColor
        case .offered, .done:
            return
        }

        let text = RECT(left: rect.left + px(Metric.sidePadding), top: rect.top,
                        right: rect.right - px(Metric.sidePadding), bottom: rect.bottom - 1)
        drawText(hdc, message, in: text, font: fonts.small, color: color,
                 format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)

        // The bar itself, along the bottom edge, in the profile's colour: the same place a browser
        // has put load progress since browsers had progress, and out of the way of the sentence.
        guard case .working = state.phase, state.fraction > 0 else { return }
        let height = px(Metric.bannerProgressHeight)
        let width = Int32(Double(rect.right - rect.left) * state.fraction)
        fill(hdc, RECT(left: rect.left, top: rect.bottom - height, right: rect.left + width,
                       bottom: rect.bottom), with: accent)
    }
}
