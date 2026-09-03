#if os(macOS)
import SwiftUI

/// What ⌃Tab shows while it is held: the profile's windows as pictures, in the order they were last
/// looked at, with the one you would land on in the middle.
///
/// It is a rail of its own, and drawn like one on purpose — cards in a row, the chosen one full size
/// between two neighbours peeking in at the edges — because that is the vocabulary the whole browser
/// already speaks. What it is *not* is the overview: the overview is where the windows are, laid out
/// in the workspaces they belong to; this is where they have been, and the two orders have nothing to
/// do with each other.
///
/// Nothing here answers the mouse. The panel exists only for as long as ⌃ is held, and a target that
/// disappears the moment you let go of a key is not a target — the pointer's way to another window is
/// the rail itself, or the overview.
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

    /// Sizes are fractions of the window, as everywhere on the rail: three windows and a bit across
    /// the middle half of the screen, each card the shape of the window it stands for.
    @ViewBuilder
    private func panel(in size: CGSize) -> some View {
        let switcher = browser.switcher
        let width = size.width * 0.52
        let card = CGSize(width: width * 0.3, height: width * 0.3 * (size.height / max(1, size.width)))
        let gap = card.width * 0.09
        let step = card.width + gap
        VStack(spacing: 14) {
            HStack(spacing: gap) {
                ForEach(Array(switcher.ring.enumerated()), id: \.element) { position, id in
                    if let tab = browser.tab(id) {
                        WindowCard(tab: tab, size: card, isChosen: position == switcher.index)
                    }
                }
            }
            // The chosen card in the middle of the panel: the row slides under it, the way the rail
            // slides under the focused window.
            .offset(x: -(CGFloat(switcher.index) - CGFloat(switcher.ring.count - 1) / 2) * step)
            .frame(width: width, alignment: .center)
            // The row runs past both ends of the panel; it fades out there rather than being cut,
            // so what is off the end reads as more windows and not as a clipped picture.
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

    /// Where the flight would land, in words: the page's title, and under it the site and the
    /// workspace it is in — a ring that crosses workspaces has to say which one, or landing is a
    /// surprise.
    @ViewBuilder
    private var caption: some View {
        if let id = browser.switcher.selection, let tab = browser.tab(id) {
            VStack(spacing: 3) {
                Text(tab.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle(of: tab))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .id(id) // a new line rather than a title morphing into another one
            .transition(.opacity)
        }
    }

    private func subtitle(of tab: BrowserTab) -> String {
        let host = tab.currentURL?.host() ?? ""
        guard let at = browser.layout.location(ofTabID: tab.id, in: tab.profileID) else { return host }
        let workspace = browser.layout.title(at: at.workspace)
        return host.isEmpty ? workspace : "\(host) · \(workspace)"
    }
}

/// One window in the ring: its last picture, or the card the rail draws when there is no picture yet.
private struct WindowCard: View {
    let tab: BrowserTab
    let size: CGSize
    let isChosen: Bool

    @Environment(BrowserState.self) private var browser

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    var body: some View {
        picture
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
    private var picture: some View {
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
                Image(systemName: tab.isDocument ? "doc.text" : "globe")
                    .font(.system(size: max(18, size.height * 0.22), weight: .light))
                    .foregroundStyle(accent)
            }
        }
        .background(.background)
    }
}
#endif
