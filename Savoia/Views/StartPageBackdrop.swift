import SwiftUI

extension StartPageStyle {
    var title: String {
        switch self {
        case .plain: String(localized: "Plain")
        case .glass: String(localized: "Glass")
        case .sky: String(localized: "Sky")
        case .clouds: String(localized: "Clouds")
        case .wings: String(localized: "Wings")
        case .aurora: String(localized: "Glow")
        }
    }
}

/// What lies behind the start page's field: the profile's tint, a translucent wash of the icon's colours with the
/// wings in it, or the sky of the icon with its clouds.
struct StartPageBackdrop: View {
    let style: StartPageStyle
    let accent: Color

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch style {
        case .plain:
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        case .glass:
            glass
        case .sky:
            sky
        case .clouds:
            ZStack {
                LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
                Clouds(light: isDark ? Color(red: 0.55, green: 0.60, blue: 0.75) : .white,
                       shade: isDark ? Color(red: 0.30, green: 0.34, blue: 0.50) : Color(red: 0.70, green: 0.78, blue: 0.92),
                       opacity: isDark ? 0.30 : 0.85)
            }
        case .wings:
            wings
        case .aurora:
            aurora
        }
    }

    private var isDark: Bool { scheme == .dark }

    private var glass: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.10, green: 0.28, blue: 0.62).opacity(0.55), Color(red: 0.96, green: 0.45, blue: 0.20).opacity(0.32)]
                               : [Color(red: 0.36, green: 0.62, blue: 0.95).opacity(0.38), Color(red: 1.0, green: 0.72, blue: 0.48).opacity(0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Two panes of frosted glass leaning the way the wings do.
                pane(width: w * 0.86, height: h * 0.36).offset(x: w * 0.12, y: -h * 0.10)
                pane(width: w * 0.62, height: h * 0.24).offset(x: -w * 0.06, y: h * 0.22)
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private func pane(width: CGFloat, height: CGFloat) -> some View {
        GlassPane(slant: 0.30)
            .fill(LinearGradient(colors: [.white.opacity(isDark ? 0.16 : 0.45), .white.opacity(isDark ? 0.03 : 0.10)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GlassPane(slant: 0.30)
                    .stroke(LinearGradient(colors: [.white.opacity(isDark ? 0.40 : 0.90), .white.opacity(0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.10), radius: width * 0.03, y: height * 0.08)
            .frame(width: width, height: height)
    }

    private var wings: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.07, green: 0.12, blue: 0.26), Color(red: 0.14, green: 0.10, blue: 0.20)]
                               : [Color(red: 0.88, green: 0.94, blue: 1.0), Color(red: 1.0, green: 0.95, blue: 0.90)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image("Wings")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width * 1.05)
                    .opacity(isDark ? 0.55 : 0.85)
                    .offset(x: geometry.size.width * 0.12, y: geometry.size.height * 0.20)
                    .mask(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var aurora: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Rectangle().fill(isDark ? Color(red: 0.05, green: 0.07, blue: 0.16) : Color(red: 0.97, green: 0.97, blue: 1.0))
                blob(Color(red: 0.25, green: 0.55, blue: 0.95), at: CGPoint(x: 0.12, y: 0.10), size: 0.70, in: geometry.size)
                blob(Color(red: 1.0, green: 0.62, blue: 0.30), at: CGPoint(x: 0.95, y: 0.85), size: 0.75, in: geometry.size)
                blob(Color(red: 0.95, green: 0.18, blue: 0.14), at: CGPoint(x: 0.62, y: 1.00), size: 0.40, in: geometry.size)
                blob(Color(red: 0.45, green: 0.35, blue: 0.85), at: CGPoint(x: 0.90, y: 0.05), size: 0.45, in: geometry.size)
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private func blob(_ color: Color, at point: CGPoint, size: Double, in area: CGSize) -> some View {
        Circle()
            .fill(color.opacity(isDark ? 0.55 : 0.50))
            .frame(width: area.width * size, height: area.width * size)
            .blur(radius: area.width * 0.10)
            .position(x: area.width * point.x, y: area.height * point.y)
    }

    private var sky: some View {
        ZStack {
            LinearGradient(stops: isDark
                           ? [.init(color: Color(red: 0.04, green: 0.09, blue: 0.22), location: 0),
                              .init(color: Color(red: 0.16, green: 0.14, blue: 0.30), location: 0.55),
                              .init(color: Color(red: 0.62, green: 0.30, blue: 0.20), location: 1)]
                           : [.init(color: Color(red: 0.25, green: 0.55, blue: 0.93), location: 0),
                              .init(color: Color(red: 0.62, green: 0.82, blue: 0.98), location: 0.6),
                              .init(color: Color(red: 0.99, green: 0.90, blue: 0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Clouds(light: isDark ? Color(red: 0.86, green: 0.58, blue: 0.48) : Color(red: 1.0, green: 0.97, blue: 0.88),
                   shade: isDark ? Color(red: 0.24, green: 0.20, blue: 0.40) : Color(red: 0.60, green: 0.72, blue: 0.92))
        }
    }
}

/// A leaning parallelogram: the shape of one wing.
private struct GlassPane: Shape {
    let slant: Double

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * slant
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Banks of cloud along the bottom edge and a few wisps higher up, as the icon has them. Every size is a share of the
/// view, and the puffs come from a fixed sequence, so a window resize moves them and does not reshuffle them.
private struct Clouds: View {
    let light: Color
    let shade: Color
    var opacity = 1.0

    private struct Bank {
        var x: Double
        var base: Double
        var width: Double
        var height: Double
        var puffs: Int
    }

    private static let banks = [
        Bank(x: 0.10, base: 1.02, width: 0.46, height: 0.20, puffs: 15),
        Bank(x: 0.86, base: 1.03, width: 0.50, height: 0.28, puffs: 18),
        Bank(x: 0.50, base: 1.06, width: 0.42, height: 0.10, puffs: 9),
        Bank(x: 0.04, base: 0.50, width: 0.16, height: 0.07, puffs: 6),
        Bank(x: 0.97, base: 0.36, width: 0.18, height: 0.06, puffs: 6),
    ]

    var body: some View {
        Canvas { context, size in
            var context = context
            context.opacity = opacity
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: size.width * 0.005))
                var random = SeededRandom(seed: 7)
                for bank in Self.banks {
                    for _ in 0..<bank.puffs {
                        let across = random.next() - 0.5
                        let lift = random.next()
                        let radius = (0.45 + random.next() * 0.55) * bank.height * size.height * 0.62
                        let x = (bank.x + across * bank.width) * size.width
                        let y = (bank.base - lift * bank.height * (1 - abs(across) * 1.3)) * size.height
                        layer.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(light))
                    }
                }
                // Lit from above: the underside of every bank takes the shade, and only where a cloud is.
                layer.blendMode = .sourceAtop
                layer.fill(Path(CGRect(origin: .zero, size: size)),
                           with: .linearGradient(Gradient(colors: [shade.opacity(0), shade.opacity(0.75)]),
                                                 startPoint: CGPoint(x: 0, y: size.height * 0.66),
                                                 endPoint: CGPoint(x: 0, y: size.height * 1.02)))
            }
        }
        .allowsHitTesting(false)
    }
}

private nonisolated struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }
}

#if os(macOS)
/// The backgrounds as small pages, each drawn by the view it stands for; the chosen one is ringed.
struct StartPageStylePicker: View {
    @Environment(ConfigurationStore.self) private var settings

    private var width: CGFloat { max(120, min(200, Platform.screenSize.width * 0.085)) }

    var body: some View {
        @Bindable var settings = settings
        Text("Background")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(StartPageStyle.allCases) { style in
                Button { settings.startPageStyle = style } label: {
                    VStack(spacing: 6) {
                        StartPageBackdrop(style: style, accent: .accentColor)
                            .background(.background)
                            .frame(width: width, height: width * 0.625)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(settings.startPageStyle == style ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                                  lineWidth: settings.startPageStyle == style ? 2.5 : 1)
                            }
                        Text(style.title)
                            .font(.caption)
                            .foregroundStyle(settings.startPageStyle == style ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(settings.startPageStyle == style ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
