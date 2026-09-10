#if os(macOS)
import AppKit
import SwiftUI

/// The verbs, where the text is.
///
/// A selection gets a small row of buttons over it; a caret in a field gets one button beside it.
/// Nothing here talks to a model on its own — the bar is a launcher, and the person pressing it is
/// the invocation. That is the whole difference between this and a browser that reads what you type.
///
/// It is a `HostedOverlay` because SwiftUI drawn over a `WKWebView` never sees the mouse: the same
/// reason the close badge on a column is one. Its size is fixed and computed, because a hosting view
/// that publishes its own size inside a SwiftUI window feeds constraints back into it.
struct PageFocusBar: View {
    let tab: BrowserTab

    @Environment(PageFocusStore.self) private var focusStore
    @Environment(AssistantStore.self) private var assistant
    @Environment(BrowserState.self) private var browser

    /// Control metrics, not layout: a button is the size of a button on any display.
    private static let button: CGFloat = 26
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 8
    /// What a labelled verb costs beside its own text: the icon, the space after it, and the
    /// padding either side.
    private static let icon: CGFloat = 15
    private static let iconGap: CGFloat = 5
    private static let labelPadding: CGFloat = 9
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    private var focus: PageFocus { focusStore[tab.id] }

    /// A bar over every text field on the web would be six pixels of noise on a search box, so the
    /// caret gets one only where writing is the point: a `<textarea>` or a rich editor. A single
    /// line input still has the verbs — they are on the ⌘K line, which is where its questions are
    /// asked anyway. A one-character selection is a stray drag, not a request.
    private var isWorthShowing: Bool {
        switch focus.kind {
        case .selection: focus.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 1
        case .caret: focus.isMultiline
        case .none: false
        }
    }

    /// The verbs are offered whatever the ⌘K line is set to — an ACP agent included, which is
    /// where they now go (`AssistantStore.run`). They used to be hidden in that case, which is how
    /// a bar with nothing in it but `…` came to hover over a selected paragraph.
    ///
    /// Text you can write in gets the verbs that write. Explain and Summarize apply there too —
    /// they apply to any selection — but four named verbs over a comment box is a bar half the
    /// width of the window, and in a box you are typing in the thing you want is Fix, not Explain.
    /// So they step back into the `…` menu, where nothing has to earn its width.
    private var actions: [AssistantAction] {
        let primary = AssistantAction.primary(for: focus)
        guard focus.isEditable else { return primary }
        let writing = primary.filter { $0.requirement != .selection }
        return writing.isEmpty ? primary : writing
    }

    private var extras: [AssistantAction] {
        let shown = Set(actions.map(\.id))
        return AssistantAction.offered(for: focus)
            .filter { !shown.contains($0.id) && $0.requirement != .page }
    }

    /// The verbs are named, not left as icons.
    ///
    /// They were icons at first, and that is how a bar of two symbols and an ellipsis came to read
    /// as a stray capsule floating near the text rather than as a thing offering to do something —
    /// worse still with an ACP agent chosen, when the two verbs were hidden and only the ellipsis
    /// was left. A word is what makes it a bar.
    ///
    /// The width is measured rather than guessed: `HostedOverlay` gets an explicit frame (a hosting
    /// view that publishes its own size inside a SwiftUI window feeds constraints back into it), so
    /// the text has to be measured in AppKit's own font before SwiftUI lays it out. "Исправить
    /// ошибки" is half again as wide as "Fix", and a guessed constant truncates one language or
    /// pads the other.
    private func itemWidth(_ action: AssistantAction) -> CGFloat {
        let text = String(localized: action.title) as NSString
        let label = ceil(text.size(withAttributes: [.font: Self.font]).width)
        return Self.icon + Self.iconGap + label + Self.labelPadding * 2
    }

    /// One more button than the verbs: the menu that carries the rest and the free question.
    private var width: CGFloat {
        actions.reduce(Self.button) { $0 + itemWidth($1) } + Self.padding * 2
    }

    private var height: CGFloat { Self.button + Self.padding * 2 }

    var body: some View {
        GeometryReader { proxy in
            if isWorthShowing, !browser.layout.isOverview {
                HostedOverlay {
                    bar.environment(assistant).environment(browser).environment(focusStore)
                }
                .frame(width: width, height: height)
                .offset(place(in: proxy.size))
                // Where the bar went, next to where the page said the text was — the only way to
                // see this one, since the bar is AppKit over a web view and no screenshot on this
                // machine can catch it (CLAUDE.md).
                .task(id: focus) {
                    guard ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil else { return }
                    let place = place(in: proxy.size)
                    Log.debug(.ui, "focus bar: rect \(focus.rect.debugDescription) in view \(proxy.size.width)×\(proxy.size.height) → \(place.width),\(place.height)")
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: focus)
    }

    /// Above the selection where there is room, below it where there is not; never off the sides.
    private func place(in size: CGSize) -> CGSize {
        let rect = focus.rect
        let above = rect.minY - height - Self.gap
        let y = above >= 0 ? above : min(rect.maxY + Self.gap, size.height - height)
        let centred = rect.midX - width / 2
        let x = min(max(centred, Self.gap), max(Self.gap, size.width - width - Self.gap))
        return CGSize(width: x, height: max(0, y))
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button { assistant.run(action, focus: focus, about: tab) } label: {
                    HStack(spacing: Self.iconGap) {
                        Image(systemName: action.symbol)
                            .frame(width: Self.icon)
                        Text(action.title)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: itemWidth(action), height: Self.button)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(extras) { action in
                    Button { assistant.run(action, focus: focus, about: tab) } label: {
                        Label { Text(action.title) } icon: { Image(systemName: action.symbol) }
                    }
                }
                if !extras.isEmpty { Divider() }
                Button("Ask…") { assistant.focusLine() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Self.button, height: Self.button)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .padding(Self.padding)
        .frame(width: width, height: height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .tint(browser.selectedProfile.color)
    }
}
#endif
