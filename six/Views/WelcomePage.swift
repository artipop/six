#if os(macOS)
import SwiftUI

/// The first window six ever opens, and the one question it has to ask.
///
/// A page and not a sheet, for the reason written on `BuiltInPage`: a browser's answer to "show me
/// something" is a window on the rail. It can be closed, it can be opened again from the menu, and
/// it teaches the layout in the act of being read — the first thing a new person does here is close
/// a column.
///
/// One question for now, because there is only one that cannot be guessed: six is built around
/// language models, and whether they run at all is not a preference to discover in a settings pane
/// three days later. Everything else six could ask — the default browser, what to block — either
/// has a right answer or asks itself at the moment it matters.
struct WelcomePage: View {
    let tab: BrowserTab

    @Environment(SettingsStore.self) private var settings
    @Environment(BrowserState.self) private var browser

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("six")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(browser.selectedProfile.color)
                Text("A browser with a rail instead of tabs: a page is a full-height window, the windows stand side by side, and the rail scrolls. ⌥← and ⌥→ move along it; ⌥↑ and ⌥↓ move between workspaces.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 28)

                Text("Should six use language models?")
                    .font(.title2.weight(.semibold))
                Text("The ⌘K line, the verbs that appear over selected text and in a field you are typing in, the agent panel, deep research, and six's own MCP server — everything that talks to a model or an agent.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Choice(title: "Yes, use them",
                           detail: "The models are chosen in Settings ▸ Assistant. The on-device one keeps everything on this Mac; the others are a key and an endpoint you enter yourself.",
                           symbol: "sparkles",
                           isProminent: true) { answer(true) }
                    Choice(title: "No, none of it",
                           detail: "Nothing is built and nothing is injected into a page: no ⌘K line, no bar over a selection, no agent, no socket. Bookmark search and page translation are not affected.",
                           symbol: "nosign",
                           isProminent: false) { answer(false) }
                }
                .padding(.top, 20)

                Text("Either way it is one switch in Settings ▸ Assistant, and it can be changed at any time.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
            // A share of the window rather than a constant: this is a column on a 5K panel and a
            // column on a laptop, and a 640-point measure is a different thing on each.
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(.background)
    }

    /// Answering is the whole of it: the switch is written, the question is marked asked, and the
    /// window closes — the rail is left empty rather than holding a page nobody needs twice.
    private func answer(_ enabled: Bool) {
        settings.isAIEnabled = enabled
        settings.hasAnsweredWelcome = true
        browser.closeTab(tab.id)
    }

    private struct Choice: View {
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        let symbol: String
        let isProminent: Bool
        let action: () -> Void

        @Environment(BrowserState.self) private var browser
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(isProminent ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.secondary))
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isProminent ? browser.selectedProfile.color.opacity(0.7) : Color.secondary.opacity(0.25),
                                      lineWidth: isProminent ? 2 : 1)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
#endif
