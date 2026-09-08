#if os(macOS)
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

    /// A verb is a prompt to a language model. While the line is set to an agent there is nothing
    /// to send it to that would not be a different model than the one chosen, so the bar keeps only
    /// its last button — the one that hands the selection to whatever is chosen.
    private var isAgent: Bool { assistant.settings.model.agentDefinition != nil }

    private var actions: [AssistantAction] {
        isAgent ? [] : AssistantAction.primary(for: focus)
    }

    private var extras: [AssistantAction] {
        isAgent ? [] : AssistantAction.offered(for: focus).filter { !$0.isPrimary && $0.requirement != .page }
    }

    /// One more button than the verbs: the menu that carries the rest and the free question.
    private var width: CGFloat {
        CGFloat(actions.count + 1) * Self.button + Self.padding * 2
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
                    Image(systemName: action.symbol)
                        .frame(width: Self.button, height: Self.button)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(action.title))
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
