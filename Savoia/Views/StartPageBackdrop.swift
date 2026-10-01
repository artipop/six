import SwiftUI

extension StartPageStyle {
    var title: String {
        switch self {
        case .plain: String(localized: "Plain")
        case .glass: String(localized: "Glass")
        case .wings: String(localized: "Wings")
        case .aurora: String(localized: "Glow")
        }
    }
}

/// What lies behind the start page's field: the profile's tint, translucent panes washed with the icon's colours,
/// the icon's wings in a corner, or blurred patches of its blue and orange.
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
