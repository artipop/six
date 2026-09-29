#if os(macOS)
import SwiftUI

/// What ⌃Tab shows while it is held: the tabs as pictures, in the order they were last looked at,
/// with the one you would land on in the middle. Nothing here answers the mouse: the panel exists
/// only for as long as ⌃ is held.
struct WindowSwitcherOverlay: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let switcher = browser.switcher
        if switcher.isOpen {
            GeometryReader { proxy in
                panel(in: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    /// Sizes are fractions of the window: three cards and a bit across the middle half of the screen.
    @ViewBuilder
    private func panel(in size: CGSize) -> some View {
        let switcher = browser.switcher
        let width = size.width * 0.52
        let card = CGSize(width: width * 0.3, height: width * 0.3 * (size.height / max(1, size.width)))
        let gap = card.width * 0.09
        let widths = switcher.ring.map { _ in card.width }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        let lead = widths.prefix(switcher.index).reduce(0) { $0 + $1 + gap }
        let centre = lead + (widths.indices.contains(switcher.index) ? widths[switcher.index] : 0) / 2
        VStack(spacing: 14) {
            HStack(spacing: gap) {
                ForEach(Array(switcher.ring.enumerated()), id: \.element) { position, id in
                    if let tab = browser.tab(id), widths.indices.contains(position) {
                        WindowCard(tab: tab, size: CGSize(width: widths[position], height: card.height),
                                   isChosen: position == switcher.index)
                    }
                }
            }
            // The chosen card in the middle of the panel, the cards sliding under it.
            .offset(x: total / 2 - centre)
            .frame(width: width, alignment: .center)
            // The cards run past both ends of the panel and fade out there rather than being cut.
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.1),
                    .init(color: .white, location: 0.9),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
            caption
                .frame(width: width * 0.9)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 26)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 40, y: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where the flight would land, in words: the page's title and the site under it. Not the
    /// workspace — the ring holds one row's windows, so every card in it is in the workspace you
    /// are already looking at, and a line saying so on every one of them says nothing.
    @ViewBuilder
    private var caption: some View {
        if let id = browser.switcher.selection, let tab = browser.tab(id) {
            VStack(spacing: 3) {
                Text(tab.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(tab.currentURL?.host() ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .id(id) // a new line rather than a title morphing into another one
            .transition(.opacity)
        }
    }
}

/// One stop in the ring: one tab.
private struct WindowCard: View {
    let tab: BrowserTab
    let size: CGSize
    let isChosen: Bool

    @Environment(BrowserState.self) private var browser

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    var body: some View {
        Self.picture(of: tab, accent: accent, size: size)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isChosen ? accent : Color.primary.opacity(0.12),
                                  lineWidth: isChosen ? 2.5 : 1)
            }
            .shadow(color: .black.opacity(isChosen ? 0.28 : 0), radius: 14, y: 6)
            // The ones either side are there to say the ring goes on, and to be recognised on the way
            // past — not to be read.
            .opacity(isChosen ? 1 : 0.55)
            .scaleEffect(isChosen ? 1 : 0.92)
    }

    @ViewBuilder
    private static func picture(of tab: BrowserTab, accent: Color, size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.18), accent.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = tab.thumbnail {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
            } else {
                Image(systemName: tab.isDocument ? "doc.text" : tab.builtIn != nil ? "gearshape" : "globe")
                    .font(.system(size: max(18, size.height * 0.22), weight: .light))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.background)
    }
}
#endif
