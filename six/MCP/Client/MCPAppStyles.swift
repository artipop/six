#if os(macOS)
import AppKit
#endif
import Foundation

/// six's own colours and type, in the names the extension standardised, so an app can look like it
/// belongs in the window it was given.
///
/// Every value is a CSS `light-dark()` pair: the spec asks for it, and it means the app follows the
/// Mac's appearance without six having to tell it twice. What is sent is a *subset* — the ones six
/// can answer honestly from the system palette. An app is instructed to keep its own fallbacks for
/// everything else, and a host that half-fills the palette is the case the spec warns about, so the
/// pairs sent here are the ones that go together: backgrounds with their text, borders with both.
nonisolated enum MCPAppStyles {
    static var variables: ACPJSON {
        #if os(macOS)
        var values: [String: ACPJSON] = [:]
        func put(_ name: String, _ color: NSColor) {
            values[name] = .string(lightDark(color))
        }
        // Backgrounds, from the window's own ground outward.
        put("--color-background-primary", .textBackgroundColor)
        put("--color-background-secondary", .controlBackgroundColor)
        put("--color-background-tertiary", .underPageBackgroundColor)
        put("--color-background-inverse", .labelColor)
        put("--color-background-info", .systemBlue.withAlphaComponent(0.12))
        put("--color-background-danger", .systemRed.withAlphaComponent(0.12))
        put("--color-background-success", .systemGreen.withAlphaComponent(0.12))
        put("--color-background-warning", .systemOrange.withAlphaComponent(0.12))
        put("--color-background-disabled", .quaternaryLabelColor)
        // Text.
        put("--color-text-primary", .labelColor)
        put("--color-text-secondary", .secondaryLabelColor)
        put("--color-text-tertiary", .tertiaryLabelColor)
        put("--color-text-inverse", .textBackgroundColor)
        put("--color-text-info", .systemBlue)
        put("--color-text-danger", .systemRed)
        put("--color-text-success", .systemGreen)
        put("--color-text-warning", .systemOrange)
        put("--color-text-disabled", .disabledControlTextColor)
        // Borders and focus rings.
        put("--color-border-primary", .separatorColor)
        put("--color-border-secondary", .gridColor)
        put("--color-border-info", .systemBlue)
        put("--color-border-danger", .systemRed)
        put("--color-ring-primary", .keyboardFocusIndicatorColor)
        put("--color-ring-danger", .systemRed)
        // Type. The system font is named rather than embedded: `-apple-system` is the one family a
        // WebKit page can ask for and be sure of getting.
        values["--font-sans"] = .string("-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif")
        values["--font-mono"] = .string("ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace")
        values["--font-weight-normal"] = "400"
        values["--font-weight-medium"] = "500"
        values["--font-weight-semibold"] = "600"
        values["--font-weight-bold"] = "700"
        // Corners, as AppKit rounds them.
        values["--border-radius-xs"] = "3px"
        values["--border-radius-sm"] = "5px"
        values["--border-radius-md"] = "7px"
        values["--border-radius-lg"] = "10px"
        values["--border-radius-xl"] = "14px"
        values["--border-radius-full"] = "9999px"
        values["--border-width-regular"] = "1px"
        return .object(values)
        #else
        return [:]
        #endif
    }

    #if os(macOS)
    /// `light-dark(#…, #…)` — the same colour resolved under both appearances, which is how a value
    /// that follows the Mac's own switch is written in CSS.
    private static func lightDark(_ color: NSColor) -> String {
        "light-dark(\(hex(color, .aqua)), \(hex(color, .darkAqua)))"
    }

    private static func hex(_ color: NSColor, _ name: NSAppearance.Name) -> String {
        var text = "#000000"
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            let r = Int((rgb.redComponent * 255).rounded())
            let g = Int((rgb.greenComponent * 255).rounded())
            let b = Int((rgb.blueComponent * 255).rounded())
            let a = Int((rgb.alphaComponent * 255).rounded())
            // Eight digits only when there is transparency to carry: a semi-transparent label colour
            // over the app's own background is exactly how AppKit draws secondary text.
            text = a >= 255
                ? String(format: "#%02x%02x%02x", r, g, b)
                : String(format: "#%02x%02x%02x%02x", r, g, b, a)
        }
        return text
    }
    #endif
}
