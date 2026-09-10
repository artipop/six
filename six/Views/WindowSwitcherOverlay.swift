#if os(macOS)
import SwiftUI

/// What ⌃Tab shows while it is held: the windows on the rail in front of you, as pictures, in the
/// order they were last looked at, with the one you would land on in the middle.
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
        // A card is as wide as the thing it stands for: a whole column, or half of one. The rail's
        // own arithmetic, in miniature — and the reason the row can no longer be laid out by
        // counting equal steps.
        let widths = switcher.ring.map { id in
            browser.ringCardIsHalfWide(id) ? (card.width - card.width * 0.02) / 2 : card.width
        }
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
            // The chosen card in the middle of the panel: the row slides under it, the way the rail
            // slides under the focused window. Measured rather than counted, because the cards are
            // no longer all one width — with equal widths this is exactly the old `-(index - (n-1)/2)
            // * step`.
            .offset(x: total / 2 - centre)
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

    /// Where the flight would land, in words: the page's title and the site under it. Not the
    /// workspace — the ring holds one rail's windows, so every card in it is in the workspace you
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

/// One stop in the ring: a picture of the **column**, which for a split is both halves side by side,
/// the way it looks on the rail.
///
/// A stop is a column and not a window (`WindowSwitcher.open`), so this draws what you would be
/// looking at after the flight rather than one of the two things in it. The half the ring actually
/// landed on is the one drawn at full strength — landing puts the focus back in it, and a card that
/// showed a pair without saying which would be a card that hid the answer.
private struct WindowCard: View {
    let tab: BrowserTab
    let size: CGSize
    let isChosen: Bool

    @Environment(BrowserState.self) private var browser

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// The windows this card stands for — the pair for a stop that is a whole column, and the one
    /// window for a stop that is half of one (`BrowserState.ringWindows(at:)`).
    private var mates: [BrowserTab] {
        browser.ringWindows(at: tab.id).compactMap { browser.tab($0) }
    }

    var body: some View {
        content
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
    private var content: some View {
        let pair = mates
        if pair.count > 1 {
            let seam = max(2, size.width * 0.02)
            let half = (size.width - seam) / 2
            HStack(spacing: seam) {
                ForEach(pair, id: \.id) { mate in
                    Self.picture(of: mate, accent: accent,
                                 size: CGSize(width: half, height: size.height))
                        // Which half you would land in. The other one is there because it is what
                        // you would be looking at, not because you are choosing it.
                        .opacity(mate.id == tab.id ? 1 : 0.5)
                }
            }
            .background(.background)
        } else {
            Self.picture(of: tab, accent: accent, size: size)
        }
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
                Image(systemName: tab.isDocument ? "doc.text" : "globe")
                    .font(.system(size: max(18, size.height * 0.22), weight: .light))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.background)
    }
}
#endif
