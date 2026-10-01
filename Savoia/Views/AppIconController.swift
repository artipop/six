#if os(macOS)
import AppKit

/// The Dock icon as chosen in Configuration ▸ Appearance ▸ App Icon. The Dock draws what the process hands it for as long as
/// it runs; a quit app is back to the bundle's icon.
@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private let bundled: NSImage
    private var settings: ConfigurationStore?
    private var appearance: NSKeyValueObservation?
    private let isDevelopment = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    private var drawn: [String: NSImage] = [:]

    private init() {
        bundled = NSApplication.shared.applicationIconImage
    }

    func start(settings: ConfigurationStore) {
        self.settings = settings
        appearance = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.apply() }
        }
        apply()
    }

    func image(for choice: AppIconChoice) -> NSImage {
        switch choice {
        case .sky: return variant("IconSky")
        case .light: return variant("IconLight")
        case .dark: return variant("IconDark")
        case .lightWings: return variant("IconLightWings")
        case .darkWings: return variant("IconDarkWings")
        case .automatic: return variant(isDark ? "IconDark" : "IconLight")
        case .automaticWings: return variant(isDark ? "IconDarkWings" : "IconLightWings")
        }
    }

    private var isDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func apply() {
        guard let settings else { return }
        let choice = withObservationTracking {
            settings.appIcon
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.apply() }
        }
        NSApplication.shared.applicationIconImage = image(for: choice)
    }

    private func variant(_ name: String) -> NSImage {
        guard let image = NSImage(named: name) else { return bundled }
        guard isDevelopment else { return image }
        if let cached = drawn[name] { return cached }
        let banded = Self.banded(image)
        drawn[name] = banded
        return banded
    }

    /// The orange DEV band of the development build's bundle icon, laid over an icon drawn at run time — once, into
    /// a bitmap, because an image with a drawing handler is drawn again every time it is shown.
    private static func banded(_ image: NSImage) -> NSImage {
        let pixels = 1024
        let size = NSSize(width: pixels, height: pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        let ctx = graphics.cgContext
        let s = rect.width
        let inset = s * 0.09
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: s * 0.185,
                           cornerHeight: s * 0.185, transform: nil))
        ctx.clip()
        ctx.translateBy(x: s * 0.70, y: s * 0.26)
        ctx.rotate(by: .pi / 4)
        ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1).cgColor)
        ctx.fill(CGRect(x: -s, y: -s * 0.075, width: 2 * s, height: s * 0.15))
        let font = NSFont.systemFont(ofSize: s * 0.095, weight: .heavy)
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: font, .foregroundColor: NSColor.black, .kern: s * 0.01,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
#endif
