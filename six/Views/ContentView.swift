#if os(macOS)
import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(AssistantStore.self) private var assistant
    /// The address field lives in the top bar now, so the focus that ⌘L moves lives beside it —
    /// above the strip, which no longer has one.
    @FocusState private var addressFocus: UUID?
    @State private var showAgentPanel = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var showFilterLists = false
    @State private var showExtensions = false
    @State private var showSitePermissions = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // Fullscreen gives the whole window to the strip; its own bar comes back on hover.
            if !browser.layout.showsFullscreen {
                TopBar(showAgentPanel: $showAgentPanel, addressFocus: $addressFocus)
                    // In front of the strip, not behind it. They are siblings in a stack, so the strip
                    // is drawn — and hit-tested — after the bar; anything of the strip's that reaches
                    // up into the bar's band would take the click off its buttons.
                    .zIndex(1)
            }
            NiriStripView()
                .overlay(alignment: .bottom) {
                    if !browser.layout.isOverview {
                        // Tucked away always, not just in fullscreen: a bar resting over the bottom of
                        // every page is in the way of the page — a video's controls sit exactly there.
                        // ⌘K brings it back (and an answer keeps it up), which is what it was for.
                        AssistantBar(isHidden: true)
                    }
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay { FlightsOverlay() }
        // Mounted once, on the root, because six is a `Window` and not a `WindowGroup`. It draws
        // nothing: it only carries the `.translationTask` that can ask for a language download.
        .translationHost(browser.appleTranslator)
        .inspector(isPresented: $showAgentPanel) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
        .tint(browser.selectedProfile.color)
        .navigationTitle(browser.selectedTab?.title ?? "six")
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction {
            browser.exitOverview()
            browser.restoreChrome() // the top bar is chrome, and a fullscreen window has none
            addressFocus = browser.selectedTabID
        })
        .focusedSceneValue(\.toggleAgentPanel, FocusAddressBarAction { showAgentPanel.toggle() })
        .focusedSceneValue(\.showHistory, FocusAddressBarAction { showHistory = true })
        .sheet(isPresented: $showHistory) { HistoryView() }
        .focusedSceneValue(\.showBookmarks, FocusAddressBarAction { showBookmarks = true })
        .sheet(isPresented: $showBookmarks) { BookmarksView() }
        .focusedSceneValue(\.showFilterLists, FocusAddressBarAction { showFilterLists = true })
        .sheet(isPresented: $showFilterLists) { BlockingView() }
        .focusedSceneValue(\.showExtensions, FocusAddressBarAction { showExtensions = true })
        .sheet(isPresented: $showExtensions) { ExtensionsView() }
        .focusedSceneValue(\.showSitePermissions, FocusAddressBarAction { showSitePermissions = true })
        .sheet(isPresented: $showSitePermissions) { PermissionsView() }
        .focusedSceneValue(\.clearHistory, FocusAddressBarAction { confirmClearHistory = true })
        .focusedSceneValue(\.translatePage, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.toggleTranslation(of: tab) }
        })
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
            // SwiftUI hands a new window's focus to the first field it finds, and that is now the
            // address field: six would open with the caret up there and the page unable to hear a
            // key. `defaultFocus(_:nil)` does not cover it — the field has to be let go of after the
            // window has settled. ⌘L is how you ask for it.
            try? await Task.sleep(for: .milliseconds(200))
            addressFocus = nil
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
            // `SIX_TRANSLATE_SELFTEST="https://ru.wikipedia.org/wiki/Браузер"` opens the address and
            // translates it, narrating each step — the download prompt is the framework's own and
            // still wants a person, but everything up to and after it can be watched from a terminal.
            if let address = ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST"],
               let url = URL(string: address) {
                await translateSelfTest(url)
            }
        }
    }
}

extension ContentView {
    /// Drives one page through translation from launch, printing what happened. A harness, in the
    /// shape the ACP and assistant ones already have.
    fileprivate func translateSelfTest(_ url: URL) async {
        func say(_ text: String) { print("[translate] \(text)"); fflush(stdout) }

        guard let tab = browser.selectedTab else { return say("no tab") }
        tab.load(url)
        for _ in 0..<80 where tab.isLoading || tab.currentURL == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("loaded \(tab.currentURL?.absoluteString ?? "nothing")")

        guard let plan = try? await browser.translation.plan(tab) else { return say("no plan") }
        say("plan: lang=\(plan.language.isEmpty ? "-" : plan.language) unsupported=\(plan.unsupported.isEmpty ? "-" : plan.unsupported) sample=\(plan.sample.prefix(60))…")
        if let refusal = plan.refusal { return say("refused: \(refusal)") }

        guard let source = TranslationLanguage.source(of: plan) else { return say("no source language") }
        let target = Locale.Language(identifier: "en")
        say("translating \(source.maximalIdentifier) -> \(target.maximalIdentifier)")
        say("status: \(await browser.appleTranslator.status(from: source, to: target))")

        let run = Task { await browser.translation.translate(tab, id: tab.id, from: source, to: target) }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            let armed = browser.appleTranslator.armedPairs.map(\.id)
            if !armed.isEmpty { say("ARMED \(armed) — the framework should be asking to download now") ; break }
            if let phase = browser.translation[tab.id]?.phase, case .working(let d, let n) = phase, n > 0 {
                say("working \(d)/\(n)")
            }
        }
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(1))
            guard let state = browser.translation[tab.id] else { continue }
            switch state.phase {
            case .done: say("DONE"); return
            case .failed(let why): say("FAILED: \(why)"); return
            case .working(let d, let n): if n > 0 { say("working \(d)/\(n)") }
            case .downloading: say("downloading a language — the system sheet is up")
            case .offered: break
            }
        }
        run.cancel()
        say("gave up waiting")
    }
}

/// The bar in the (hidden) title bar area — the window's one piece of chrome, and now the only one.
///
/// Left: which profile you are in, and how the layout is showing the strip. Middle: the focused
/// window's address, because that band of the window was empty and an address field is exactly the
/// shape of it. Right: everything about the strip rather than the page — what is bookmarked and
/// downloading, where in the stack of workspaces you are, the overview, the agent.
private struct TopBar: View {
    @Binding var showAgentPanel: Bool
    var addressFocus: FocusState<UUID?>.Binding
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 1) // room for the window buttons
            ProfileMenuButton()
            LayoutModeButton()
            Spacer(minLength: 8)
            if let tab = browser.selectedTab {
                AddressBar(tab: tab, addressFocus: addressFocus)
                    .frame(maxWidth: addressWidth)
            }
            Spacer(minLength: 8)
            BookmarkButton()
            DownloadsButton()
            ExtensionActionBar()
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
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A share of the window rather than a number of points: on a 5K panel a fixed field is a slot in
    /// the middle of nowhere, and on a laptop it crowds out the buttons on either side. The floor and
    /// the ceiling are the two places where a share stops being sensible.
    private var addressWidth: CGFloat {
        max(280, min(760, browser.layout.viewport.width * 0.4))
    }
}

/// How the strip is showing the focused window, as one control: click to fill the window and back
/// (⌥W), hold for the rest — the three fills, the shared column width, the overview.
///
/// It replaces the button that used to sit inside a compact window and expand it. That button could
/// only ever say one thing and could only be reached in one mode; a mode picker says where you are
/// as well as where you can go, and it is in the same place whichever mode you are in.
private struct LayoutModeButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        Menu {
            Picker("View", selection: Binding(get: { layout.fill }, set: { setFill($0) })) {
                Label("Strip", systemImage: "rectangle.split.3x1").tag(NiriFill.tiled)
                Label("Full Window (⌥W)", systemImage: "rectangle.inset.filled").tag(NiriFill.window)
                Label("Fullscreen (⌥⇧F)", systemImage: "arrow.up.left.and.arrow.down.right").tag(NiriFill.screen)
            }
            .pickerStyle(.inline)
            Divider()
            ColumnWidthPicker()
            Toggle("Compact Width (⌥F)", isOn: Binding(
                get: { layout.focusedColumnIsFullWidth },
                set: { _ in browser.toggleCompactWidth() }
            ))
            .disabled(layout.fillsViewport)
            Divider()
            Toggle("Overview (⌥O)", isOn: Binding(get: { layout.isOverview }, set: { _ in browser.toggleOverview() }))
            Toggle("Centre Focused Window (⌥C)", isOn: Binding(
                get: { layout.centersFocus },
                set: { _ in browser.toggleCenterFocus() }
            ))
            Divider()
            // Where a window is in the strip, and the way out of it. These used to hang off its
            // title bar; the page runs edge to edge now, so they hang off the layout button and off
            // the page's own context menu.
            Button("Move Left (⌥⇧←)") { browser.moveColumn(-1) }
            Button("Move Right (⌥⇧→)") { browser.moveColumn(1) }
            Button("Move to Workspace Above (⌥⇧↑)") { browser.moveColumnToWorkspace(-1) }
            Button("Move to Workspace Below (⌥⇧↓)") { browser.moveColumnToWorkspace(1) }
            Divider()
            Button("Close Window (⌘W)") { browser.closeSelectedTab() }
                .disabled(browser.selectedTabID == nil)
        } label: {
            Image(systemName: symbol(layout.showsFill))
                .font(.system(size: 12))
        } primaryAction: {
            browser.toggleFullWindow()
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("How the strip is shown — click fills the window (⌥W)")
    }

    private func setFill(_ fill: NiriFill) {
        switch fill {
        case .tiled: browser.restoreChrome()
        case .window: if browser.layout.fill != .window { browser.toggleFullWindow() }
        case .screen: if browser.layout.fill != .screen { browser.toggleFullscreen() }
        }
    }

    private func symbol(_ fill: NiriFill) -> String {
        switch fill {
        case .tiled: "rectangle.split.3x1"
        case .window: "rectangle.inset.filled"
        case .screen: "arrow.up.left.and.arrow.down.right"
        }
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
                    .help(workspace.isEmpty
                          ? String(localized: "\(layout.title(at: index)) (empty)")
                          : "\(layout.title(at: index)) · \(String(localized: "\(workspace.columns.count) windows"))")
            }
        }
        .animation(NiriLayout.switchAnimation, value: layout.focusedWorkspaceIndex)
    }
}
#endif
