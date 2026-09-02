#if os(macOS)
import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(AssistantStore.self) private var assistant
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(SettingsStore.self) private var settings
    /// The address field lives in the top bar now, so the focus that ⌘L moves lives beside it —
    /// above the strip, which no longer has one.
    @FocusState private var addressFocus: UUID?
    @State private var showAgentPanel = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showAgentPanel: $showAgentPanel, addressFocus: $addressFocus)
                // In front of the rail, not behind it. They are siblings in a stack, so the rail is
                // drawn — and hit-tested — after the bar; anything of the rail's that reaches up into
                // the bar's band would take the click off its buttons.
                .zIndex(1)
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
            addressFocus = browser.selectedTabID
        })
        .focusedSceneValue(\.toggleAgentPanel, FocusAddressBarAction { showAgentPanel.toggle() })
        .modifier(Panels(history: $showHistory, bookmarks: $showBookmarks))
        .focusedSceneValue(\.clearHistory, FocusAddressBarAction { confirmClearHistory = true })
        .focusedSceneValue(\.translatePage, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.toggleTranslation(of: tab) }
        })
        .focusedSceneValue(\.translateSelection, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.translateSelection(of: tab) }
        })
        .clearHistoryDialog(isPresented: $confirmClearHistory)
        .onKeyPress(.escape) {
            // The scroll monitor usually gets there first (a page holds the focus); this is the path
            // for when nothing in the window has taken the key.
            guard browser.layout.isOverview else { return .ignored }
            browser.exitOverview()
            return .handled
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
            // `SIX_MCP_PANEL=1` opens the servers page on launch, so it can be looked at without
            // reaching for the menu (docs/mcp-apps.md).
            if ProcessInfo.processInfo.environment["SIX_MCP_PANEL"] != nil { browser.openBuiltIn(.apps) }
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
            // `SIX_PERSONAL_SELFTEST="плов"` asks the start page's personal rows what they would
            // show for that query and prints both what the index answered and what survived the
            // floor — which is the only way to tune the floor against real bookmarks.
            if let query = ProcessInfo.processInfo.environment["SIX_PERSONAL_SELFTEST"], !query.isEmpty {
                await personalSelfTest(query)
            }
        }
    }
}

extension ContentView {
    /// Runs each `;`-separated query through the personal rows the way the start page does, and says
    /// what the index answered before `PersonalSuggestions` had its say — which is the only way to
    /// tune the cutoff against real bookmarks. The first query pays for loading the embedder (and,
    /// if the weights aren't down yet, for downloading them).
    fileprivate func personalSelfTest(_ queries: String) async {
        for query in queries.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !query.isEmpty {
            await personalSelfTest(one: query)
        }
    }

    fileprivate func personalSelfTest(one query: String) async {
        func say(_ text: String) { print("[personal] \(text)"); fflush(stdout) }

        let profileID = browser.selectedProfile.id
        let scope = settings.bookmarkScope
        say("query \(query.debugDescription) · scope \(scope.rawValue) · profile \(browser.selectedProfile.name)")
        say("bookmarks in scope: \(bookmarks.count(in: scope, profileID: profileID)) · embedder \(bookmarks.embedder.modelID)")

        let started = ContinuousClock.now
        let all = await bookmarks.search(query, in: scope, profileID: profileID, limit: 12)
        say("the index answered \(all.count) in \(ContinuousClock.now - started):")
        for hit in all {
            say(String(format: "  %.3f  ", hit.score) + hit.bookmark.displayTitle + "  — " + hit.snippet.prefix(70).replacingOccurrences(of: "\n", with: " "))
        }

        let personal = PersonalSuggestions()
        personal.update(for: query, in: bookmarks, scope: scope, profileID: profileID)
        for _ in 0..<80 where personal.hits.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("the field would show \(personal.hits.count):")
        for hit in personal.hits {
            say(String(format: "  %.3f  ", hit.score) + hit.bookmark.displayTitle + "  · " + hit.bookmark.displayDetail)
        }
    }

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

        await browser.appleTranslator.loadLanguages()
        let offered = browser.appleTranslator.languages
        say("menu offers \(offered.count) languages: \(offered.prefix(6).map { AppleTranslator.name(of: $0) }.joined(separator: ", "))…")
        say("target from settings: \(AppleTranslator.name(of: browser.translationTarget))")

        guard let plan = try? await browser.translation.plan(tab) else { return say("no plan") }
        say("plan: lang=\(plan.language.isEmpty ? "-" : plan.language) unsupported=\(plan.unsupported.isEmpty ? "-" : plan.unsupported) sample=\(plan.sample.prefix(60))…")
        if let refusal = plan.refusal { return say("refused: \(refusal)") }

        guard let source = TranslationLanguage.source(of: plan) else { return say("no source language") }
        say("the button would offer: \(browser.suggestedTargets(excluding: source).map { AppleTranslator.name(of: $0) })")

        // `SIX_TRANSLATE_SELFTEST_TARGETS="en,de"` runs the page through more than one language in
        // a row, which is the case that found the stale armed pair: the second language's download
        // sheet never came up while the first one's task was still mounted.
        let codes = (ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST_TARGETS"] ?? "en")
            .split(separator: ",").map(String.init)
        for code in codes {
            await runOnce(tab, source: source, target: Locale.Language(identifier: code), say: say)
        }
        say("armed at the end: \(browser.appleTranslator.armedPairs.map(\.id))")

        // `SIX_TRANSLATE_SELFTEST_SELECTION=1` selects a paragraph and opens the system popover.
        if ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST_SELECTION"] == "1" {
            _ = try? await tab.runScript("""
            const p = document.querySelector('p');
            const range = document.createRange();
            range.selectNodeContents(p);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return p.textContent.slice(0, 40);
            """)
            browser.translateSelection(of: tab)
            try? await Task.sleep(for: .seconds(2))
            say("selection: \(browser.translation.selection.prefix(50))…")
            say("editable: \(browser.translation.selectionIsEditable), popover up: \(browser.translation.showsSelection)")
        }
    }

    fileprivate func runOnce(
        _ tab: BrowserTab, source: Locale.Language, target: Locale.Language,
        say: @escaping (String) -> Void
    ) async {
        browser.translation.forget(tab.id)
        say("--- \(source.maximalIdentifier) -> \(target.maximalIdentifier), status \(await browser.appleTranslator.status(from: source, to: target))")

        let run = Task { await browser.translation.translate(tab, id: tab.id, from: source, to: target) }
        var sawArmed = false
        var sawDownloading = false
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(500))
            let armed = browser.appleTranslator.armedPairs.map(\.id)
            if !armed.isEmpty, !sawArmed {
                sawArmed = true
                say("ARMED \(armed) — the framework should be asking to download now")
            }
            guard let state = browser.translation[tab.id] else { continue }
            switch state.phase {
            case .done: say("DONE"); return
            case .failed(let why): say("FAILED: \(why)"); return
            case .working(let d, let n) where n > 0 && d % 300 == 0: say("working \(d)/\(n)")
            case .downloading:
                if !sawDownloading { sawDownloading = true; say("PHASE .downloading — the spinner should be turning") }
            default: break
            }
        }
        run.cancel()
        say("gave up waiting")
    }
}

/// The bar in the (hidden) title bar area — the window's one piece of chrome, and now the only one.
///
/// Left: which profile you are in, and how the layout is showing the strip. Middle: the focused
/// window's address, with the star against its trailing edge — the two things that are about the
/// page you are reading, because that band of the window was empty and an address field is exactly
/// the shape of it. Right: everything about the strip rather than the page — what is downloading,
/// where in the stack of workspaces you are, the overview, the agent.
/// The two panels that are opened from a menu item: each one is a focused value the menu reaches
/// across the scene, and a sheet that answers it.
///
/// There were six. Filter lists, extensions, site permissions and certificates were the other four,
/// and every one of them was a settings screen wearing a sheet — a thing that covers the window it
/// is describing so that it can describe it. They are sections of `six://settings` now. History and
/// bookmarks stay sheets because they are not settings: they are a search over everything, asked in
/// passing (⌘Y, ⌘⌥B) and closed again.
///
/// They are a modifier rather than more lines on the body because the body had reached the size
/// where the type checker gives up on it — *"unable to type-check this expression in reasonable
/// time"*, which arrives all at once when a chain grows by one. Anything added here goes in this
/// list, not up there.
private struct Panels: ViewModifier {
    @Binding var history: Bool
    @Binding var bookmarks: Bool

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.showHistory, FocusAddressBarAction { history = true })
            .sheet(isPresented: $history) { HistoryView() }
            .focusedSceneValue(\.showBookmarks, FocusAddressBarAction { bookmarks = true })
            .sheet(isPresented: $bookmarks) { BookmarksView() }
    }
}

private struct TopBar: View {
    @Binding var showAgentPanel: Bool
    var addressFocus: FocusState<UUID?>.Binding
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 1) // room for the window buttons
            ProfileMenuButton()
            FullWidthButton()
            Spacer(minLength: 8)
            // Against the field, not out with the rail's buttons. The star is about the page whose
            // address is right there — it fills for that page and ⌘D toggles it — and every browser
            // that has one keeps it at the end of the address field for exactly that reason. Out on
            // the right it sat among the things that describe the *strip*, and read as one of them.
            //
            // Which is also why it comes and goes with the field rather than outliving it. On an
            // empty workspace there is no focused window, the field is not drawn, and a star left
            // behind on its own is a control about nothing — greyed out, in the middle of the bar,
            // beside a page that says "New Window".
            if let tab = browser.selectedTab {
                AddressBar(tab: tab, addressFocus: addressFocus)
                    .frame(maxWidth: addressWidth)
                BookmarkButton(tab: tab)
            }
            Spacer(minLength: 8)
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
        // The focused page's progress, along the bottom edge of the bar that carries its address —
        // where the hairline under a window's title bar used to be, before the description moved up
        // here and the window became the page. It replaces the divider rather than sitting beside
        // it: two lines a point apart is a border with a bug in it.
        .overlay(alignment: .bottom) {
            if let tab = browser.selectedTab, !tab.isDocument, tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress, accent: accent(of: tab))
            } else {
                Divider()
            }
        }
        .animation(.easeOut(duration: 0.2), value: browser.selectedTab?.isLoading)
    }

    private func accent(of tab: BrowserTab) -> Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// A share of the window rather than a number of points: on a 5K panel a fixed field is a slot in
    /// the middle of nowhere, and on a laptop it crowds out the buttons on either side. The floor and
    /// the ceiling are the two places where a share stops being sensible.
    private var addressWidth: CGFloat {
        max(280, min(760, browser.layout.viewport.width * 0.4))
    }
}

/// Full width, as one button: the focused page keeps its gaps and its rounded corners, or takes the
/// whole window (⌥W).
///
/// It used to be a mode picker with a menu hanging off it — three fills, the overview, the centring
/// switch, and where the focused window goes in the rail. Two of those three fills were the same
/// answer to the same question, the two switches are settings and now live on `six://settings`, and
/// moving a window is what the page's own right-click menu is for. What was left is one thing with
/// two states, and a thing with two states is a button.
private struct FullWidthButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let filled = browser.layout.showsFill == .window
        Button { browser.toggleFullWindow() } label: {
            Image(systemName: filled ? "rectangle.inset.filled" : "rectangle.split.3x1")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(filled ? AnyShapeStyle(browser.selectedProfile.color.opacity(0.22))
                           : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(filled ? "Back to the rail (⌥W)" : "Full Width (⌥W)")
    }
}

/// The star: filled when the page this bar is describing is bookmarked; a click saves it (or forgets
/// it). It takes that window rather than reading the selection, because it is only ever drawn beside
/// that window's address — there is no state of this button that means "no window".
private struct BookmarkButton: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        let saved = bookmarks.isBookmarked(tab)
        let indexing = tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) }
            .map { bookmarks.indexing.contains($0.id) } ?? false
        Button {
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
        .disabled(tab.showsStartPage || browser.isPrivate(tab.profileID))
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
