import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(AssistantStore.self) private var assistant
    @State private var showAgentPanel = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // Fullscreen gives the whole window to the strip; its own bar comes back on hover.
            if !browser.layout.showsFullscreen {
                TopBar(showAgentPanel: $showAgentPanel)
                    // In front of the strip, not behind it. They are siblings in a stack, so the strip
                    // is drawn — and hit-tested — after the bar; anything of the strip's that reaches
                    // up into the bar's band would take the click off its buttons.
                    .zIndex(1)
            }
            NiriStripView()
                .overlay(alignment: .bottom) {
                    if !browser.layout.isOverview {
                        AssistantBar(isHidden: browser.layout.showsFullscreen)
                    }
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .inspector(isPresented: $showAgentPanel) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
        .tint(browser.selectedProfile.color)
        .navigationTitle(browser.selectedTab?.title ?? "six")
        .focusedSceneValue(\.toggleAgentPanel, FocusAddressBarAction { showAgentPanel.toggle() })
        .focusedSceneValue(\.showHistory, FocusAddressBarAction { showHistory = true })
        .sheet(isPresented: $showHistory) { HistoryView() }
        .focusedSceneValue(\.showBookmarks, FocusAddressBarAction { showBookmarks = true })
        .sheet(isPresented: $showBookmarks) { BookmarksView() }
        .focusedSceneValue(\.clearHistory, FocusAddressBarAction { confirmClearHistory = true })
        .clearHistoryDialog(isPresented: $confirmClearHistory)
        .onKeyPress(.escape) {
            // The scroll monitor usually gets there first (a page holds the focus); this is the path
            // for when nothing in the window has taken the key.
            if browser.layout.isOverview {
                browser.exitOverview()
                return .handled
            }
            if browser.layout.fill == .screen {
                browser.exitFullscreen()
                return .handled
            }
            return .ignored
        }
        .task {
            // Debug harness: `SIX_ACP_SELFTEST="hi"` opens the agent panel and sends the text on launch,
            // so the ACP path can be exercised (with SIX_ACP_TRACE=1) without clicking.
            if let text = ProcessInfo.processInfo.environment["SIX_ACP_SELFTEST"], !text.isEmpty {
                showAgentPanel = true
                try? await Task.sleep(for: .seconds(1))
                agentSession.send(text)
            }
            // `SIX_ASSISTANT_SELFTEST="acp:claude-code:open example.com"` does the same through the ⌘K line.
            if let spec = ProcessInfo.processInfo.environment["SIX_ASSISTANT_SELFTEST"],
               let split = spec.range(of: ":", options: .backwards),
               let model = ModelChoice(rawValue: String(spec[..<split.lowerBound])) {
                assistant.settings.model = model
                try? await Task.sleep(for: .seconds(1))
                assistant.ask(String(spec[split.upperBound...]), about: browser.selectedTab)
            }
        }
    }
}

/// Slim bar in the (hidden) title bar area: profiles on the left, workspace position on the right.
private struct TopBar: View {
    @Binding var showAgentPanel: Bool
    @Environment(BrowserState.self) private var browser
    @State private var isAddingProfile = false

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 10) {
            Color.clear.frame(width: 68, height: 1) // room for the window buttons
            ProfileSwitcher(isAddingProfile: $isAddingProfile)
            Spacer(minLength: 12)
            BookmarkButton()
            WorkspaceStepper()
            Button { browser.toggleOverview() } label: {
                Image(systemName: layout.isOverview ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
            }
            .buttonStyle(.borderless)
            .help("Overview (⌥O)")
            Button { showAgentPanel.toggle() } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("Agent panel (⌘⇧A)")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $isAddingProfile) { NewProfileSheet() }
    }
}

/// The star: filled when the focused page is bookmarked; a click saves it (or forgets it).
private struct BookmarkButton: View {
    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        let tab = browser.selectedTab
        let saved = tab.map { bookmarks.isBookmarked($0) } ?? false
        let indexing = tab.flatMap { tab in tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) } }.map { bookmarks.indexing.contains($0.id) } ?? false
        Button {
            guard let tab else { return }
            if saved, let url = tab.currentURL, let existing = bookmarks.bookmark(for: url, in: tab.profileID) {
                bookmarks.remove(existing.id)
            } else {
                Task { try? await bookmarks.add(tab) }
            }
        } label: {
            // Saved is saved: the star fills as soon as the row exists. The embedding that follows is the
            // index's business and shows in the bookmarks window — a spinner here reads as "still saving".
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .foregroundStyle(saved ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .disabled(tab == nil || tab?.showsStartPage == true || tab.map { browser.isPrivate($0.profileID) } == true)
        .help(saved ? (indexing ? "Saved; indexing for search… Remove Bookmark (⌘D)" : "Remove Bookmark (⌘D)") : "Add Bookmark (⌘D)")
    }
}

/// The workspace indicator with a chevron on each side, so the vertical stack is reachable by mouse.
private struct WorkspaceStepper: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 6) {
            Button { browser.focusWorkspace(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!layout.canFocusWorkspace(-1))
                .help("Workspace above (⌥↑)")
            WorkspacePips()
            Button { browser.focusWorkspace(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!layout.canFocusWorkspace(1))
                .help("Workspace below (⌥↓)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Vertical position in the workspace stack — niri's workspace indicator, laid out horizontally.
private struct WorkspacePips: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 4) {
            ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                let current = index == layout.focusedWorkspaceIndex
                Capsule()
                    .fill(current ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.quaternary))
                    .frame(width: current ? 20 : 8, height: 6)
                    .overlay {
                        if workspace.isEmpty && !current {
                            Capsule().strokeBorder(.tertiary, lineWidth: 1)
                        }
                    }
                    .onTapGesture { browser.focusWorkspace(at: index) }
                    .help(layout.title(at: index) + (workspace.isEmpty ? " (empty)" : " · \(workspace.columns.count) window(s)"))
            }
        }
        .animation(NiriLayout.switchAnimation, value: layout.focusedWorkspaceIndex)
    }
}

private struct ProfileSwitcher: View {
    @Environment(BrowserState.self) private var browser
    @Binding var isAddingProfile: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(browser.profiles) { profile in
                let selected = profile.id == browser.selectedProfileID
                Button {
                    browser.selectProfile(profile.id)
                } label: {
                    Circle()
                        .fill(profile.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                        }
                        .overlay {
                            if profile.isPrivate {
                                Image(systemName: "eyeglasses")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text(String(profile.name.prefix(1)))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(profile.isPrivate ? "Private browsing — nothing is kept; close it to forget the session" : profile.name)
                .contextMenu {
                    if profile.isPrivate {
                        Button("Close Private Browsing") { browser.closePrivateBrowsing() }
                    } else {
                        Button("Delete Profile", role: .destructive) { browser.removeProfile(profile.id) }
                            .disabled(browser.profiles.count == 1)
                    }
                }
            }
            Button { isAddingProfile = true } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New Profile")
        }
    }
}

private struct NewProfileSheet: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = Color.purple

    var body: some View {
        Form {
            TextField("Name", text: $name)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Create") {
                    browser.addProfile(name: name, colorHex: color.hexString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }
}

private extension Color {
    var hexString: String {
        let resolved = resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded()), g = Int((resolved.green * 255).rounded()), b = Int((resolved.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

// MARK: - Focus plumbing for ⌘L

struct FocusAddressBarAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var focusAddressBar: FocusAddressBarAction?
}
