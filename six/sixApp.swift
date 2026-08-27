import SQLiteData
import SwiftUI

/// The binary is two things: the browser, and — with `--mcp` — a stdio MCP server that relays to the
/// running browser (see `MCPStdioBridge`). The switch happens before AppKit is touched.
@main
enum SixMain {
    static func main() {
        if MCPStdioBridge.isRequested { MCPStdioBridge.run() }
        signal(SIGPIPE, SIG_IGN) // a vanished MCP client or agent must not kill the app
        MainActor.assumeIsolated { sixApp.main() }
    }
}

struct sixApp: App {
    @NSApplicationDelegateAdaptor(ExternalOpenDelegate.self) private var externalOpen
    @State private var browser: BrowserState
    @State private var assistant: AssistantStore
    @State private var agentSession: AgentSessionStore
    @State private var mcp: MCPHost
    @State private var settings: SettingsStore
    @State private var bookmarks: BookmarkStore
    @State private var window: WindowState
    @State private var highlights: HighlightStore
    @State private var research: ResearchCoordinator
    @State private var persistence: StatePersistence<FileSnapshotStore<AppStateSnapshot>>

    init() {
        let store = FileSnapshotStore<AppStateSnapshot>(fileNamed: "state.json")
        let snapshot = Self.load(store)
        // The database is the app's ground: without it there is nothing to run on.
        let database: any DatabaseWriter
        do {
            database = try AppDatabase.open()
        } catch {
            fatalError("six: cannot open \(AppDatabase.url.path): \(error)")
        }
        let settings = SettingsStore(database: database)
        SettingsStore.shared = settings
        let history = HistoryStore(database: database)
        let browser = BrowserState(snapshot: snapshot?.browser, history: history, settings: settings)
        let bookmarks = BookmarkStore(database: database, embedder: MLXEmbedder(modelsDirectory: AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)))
        bookmarks.profile = { [weak browser] id in browser?.profiles.first { $0.id == id } }
        bookmarks.dataStore = { [weak browser] profile in browser?.dataStore(for: profile) }
        bookmarks.refreshDays = { [weak settings] in settings?.bookmarkRefreshDays ?? 7 }
        bookmarks.startRefreshSchedule()
        browser.bookmarks = bookmarks
        bookmarks.resumeIndexing()
        if ProcessInfo.processInfo.environment["SIX_EMBED_SELFTEST"] != nil, let mlx = bookmarks.embedder as? MLXEmbedder {
            Task { FileHandle.standardError.write(Data("[six] embed selftest:\n\(await mlx.diagnostics())\n".utf8)) }
        }
        let highlights = HighlightStore()
        browser.highlights = highlights
        let assistant = AssistantStore(settings: settings)
        let agentSession = AgentSessionStore(snapshot: snapshot?.agent, settings: settings)
        agentSession.browser = browser
        let research = ResearchCoordinator(browser: browser, agentSession: agentSession, settings: settings)
        let tools = BrowserToolCatalog(browser: browser, assistant: assistant.settings, bookmarks: bookmarks, settings: settings, highlights: highlights)
        assistant.tools = tools
        assistant.agentSession = agentSession
        assistant.research = research
        let mcp = MCPHost(server: MCPServer(catalog: tools))
        mcp.start()
        FileHandle.standardError.write(Data("[six] \(mcp.status); state at \(store.url.path)\n".utf8))
        // Links handed to six from outside land in a new window in the strip.
        ExternalOpenDelegate.handler = { [weak browser] url in
            browser?.newTab(url: url)
        }
        let window = WindowState(snapshot: snapshot?.window)
        let persistence = StatePersistence(store: store) {
            AppStateSnapshot(browser: browser.snapshot, agent: agentSession.snapshot, window: window.snapshot)
        }
        persistence.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { persistence.flush(); browser.flushDocuments() }
        }
        _settings = State(initialValue: settings)
        _bookmarks = State(initialValue: bookmarks)
        _window = State(initialValue: window)
        _persistence = State(initialValue: persistence)
        _browser = State(initialValue: browser)
        _assistant = State(initialValue: assistant)
        _agentSession = State(initialValue: agentSession)
        _mcp = State(initialValue: mcp)
        _highlights = State(initialValue: highlights)
        _research = State(initialValue: research)
    }

    /// A file that won't load starts fresh — better than not starting.
    private static func load<S: SnapshotStore>(_ store: S) -> S.Snapshot? {
        do {
            return try store.load()
        } catch {
            FileHandle.standardError.write(Data("[six] load failed (\(S.Snapshot.self)), starting fresh: \(error)\n".utf8))
            return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(browser)
                .environment(assistant)
                .environment(agentSession)
                .environment(mcp)
                .environment(settings)
                .environment(bookmarks)
                .environment(highlights)
                .environment(research)
                .background(WindowObserver(state: window))
                // six is one window: every page in the strip is a `WebPage`, and a second window would
                // put the same objects into a second `WebView` — WebKit traps on that. Without this,
                // SwiftUI answers an external open by building a window instead of using the one that
                // is up. `"*"` is the wildcard: this window takes every external event.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1500, height: 950)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                // Read once, when the menus are built: if six already holds http/https there is
                // nothing to ask macOS for.
                Button("Set six as Default Browser…") {
                    Task { await DefaultBrowser.makeDefault() }
                }
                .disabled(DefaultBrowser.isDefault)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window in Strip") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("Close Window") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            FileCommands(browser: browser, highlights: highlights)
            LayoutCommands(browser: browser)
            BrowserCommands(settings: settings)
            HistoryCommands(browser: browser)
            BookmarkCommands(browser: browser, bookmarks: bookmarks, settings: settings)
        }
    }
}

/// niri's bindings, with ⌥ standing in for Mod.
private struct LayoutCommands: Commands {
    let browser: BrowserState

    var body: some Commands {
        CommandMenu("Layout") {
            Button("Focus Column Left") { browser.focusColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Focus Column Right") { browser.focusColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Focus First Column") { browser.focusColumnEdge(last: false) }
                .keyboardShortcut(.home, modifiers: .option)
            Button("Focus Last Column") { browser.focusColumnEdge(last: true) }
                .keyboardShortcut(.end, modifiers: .option)

            Divider()

            Button("Move Column Left") { browser.moveColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Button("Move Column Right") { browser.moveColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])

            Divider()

            Button("Focus Workspace Up") { browser.focusWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Focus Workspace Down") { browser.focusWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Move Column to Workspace Up") { browser.moveColumnToWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Move Column to Workspace Down") { browser.moveColumnToWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])

            Divider()

            Button("Wider Columns") { browser.stepColumnWidth(1) }
                .keyboardShortcut("r", modifiers: .option)
                .disabled(browser.layout.preferredWidthIndex == NiriLayout.widthPresets.count - 1)
            Button("Narrower Columns") { browser.stepColumnWidth(-1) }
                .keyboardShortcut("r", modifiers: [.option, .shift])
                .disabled(browser.layout.preferredWidthIndex == 0)
            Picker("Column Width", selection: Binding(
                get: { browser.layout.preferredWidthIndex },
                set: { browser.setColumnWidth($0) }
            )) {
                ForEach(Array(NiriLayout.widthPresets.enumerated()), id: \.offset) { index, fraction in
                    Text(NiriLayout.widthPresetTitles[index]).tag(index)
                }
            }
            .pickerStyle(.inline)
            Toggle("Compact Width", isOn: Binding(
                get: { browser.layout.focusedColumnIsFullWidth },
                set: { _ in browser.toggleCompactWidth() }
            ))
            .keyboardShortcut("f", modifiers: .option)
            Toggle("Full Window", isOn: Binding(
                get: { browser.layout.fill == .window },
                set: { _ in browser.toggleFullWindow() }
            ))
            .keyboardShortcut("w", modifiers: .option)
            Toggle("Fullscreen", isOn: Binding(
                get: { browser.layout.fill == .screen },
                set: { _ in browser.toggleFullscreen() }
            ))
            .keyboardShortcut("f", modifiers: [.option, .shift])
            Button("Toggle Overview") { browser.toggleOverview() }
                .keyboardShortcut("o", modifiers: .option)

            Divider()

            Toggle("Center Focused Window", isOn: Binding(
                get: { browser.layout.centersFocus },
                set: { _ in browser.toggleCenterFocus() }
            ))
            .keyboardShortcut("c", modifiers: .option)
        }
    }
}

/// The selected profile's recent pages, and ⌘Y for the whole thing.
private struct HistoryCommands: Commands {
    let browser: BrowserState
    @FocusedValue(\.showHistory) private var showHistory
    @FocusedValue(\.clearHistory) private var clearHistory

    var body: some Commands {
        CommandMenu("History") {
            Button("Show History…") { showHistory?.perform() }
                .keyboardShortcut("y")
                .disabled(showHistory == nil)
            Divider()
            let profile = browser.selectedProfile
            Section(profile.name) {
                let recent = browser.history.recent(in: profile.id, limit: 20)
                if recent.isEmpty {
                    Text("No History").disabled(true)
                }
                ForEach(recent) { entry in
                    Button(SearchEngine.search(from: entry.url).map { "\($0.query) — \($0.engine.title) Search" } ?? entry.displayTitle) {
                        browser.newTab(url: entry.url, in: entry.profileID)
                    }
                }
            }
            Divider()
            Button("Clear \(profile.name) History…") { clearHistory?.perform() }
                .disabled(clearHistory == nil)
        }
    }
}

/// ⌘D saves the page; the menu lists the profile's recent bookmarks and sets what the assistant searches.
private struct BookmarkCommands: Commands {
    let browser: BrowserState
    let bookmarks: BookmarkStore
    let settings: SettingsStore
    @FocusedValue(\.showBookmarks) private var showBookmarks

    var body: some Commands {
        CommandMenu("Bookmarks") {
            let tab = browser.selectedTab
            let saved = tab.map { bookmarks.isBookmarked($0) } ?? false
            Button(saved ? "Remove Bookmark" : "Add Bookmark") {
                guard let tab else { return }
                if saved, let url = tab.currentURL, let existing = bookmarks.bookmark(for: url, in: tab.profileID) {
                    bookmarks.remove(existing.id)
                } else {
                    Task { try? await bookmarks.add(tab) }
                }
            }
            .keyboardShortcut("d")
            .disabled(tab == nil || tab?.showsStartPage == true)
            Button("Show Bookmarks…") { showBookmarks?.perform() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(showBookmarks == nil)
            Divider()
            @Bindable var settings = settings
            Picker("Assistant Searches", selection: $settings.bookmarkScope) {
                ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            let profile = browser.selectedProfile
            let current = tab.flatMap { tab in tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) } }
            Button("Refresh Bookmark") { if let current { Task { await bookmarks.refresh(current.id) } } }
                .disabled(current == nil)
            Button("Refresh \(profile.name) Bookmarks") { bookmarks.refreshAll(in: profile.id) }
                .disabled(bookmarks.count(in: profile.id) == 0)
            Picker("Re-read Saved Pages", selection: $settings.bookmarkRefreshDays) {
                Text("Never").tag(0)
                Text("Daily").tag(1)
                Text("Weekly").tag(7)
                Text("Monthly").tag(30)
            }
            Divider()
            Section(profile.name) {
                let recent = bookmarks.entries(in: .profile, profileID: profile.id).prefix(15)
                if recent.isEmpty {
                    Text("No Bookmarks").disabled(true)
                }
                ForEach(Array(recent)) { entry in
                    Button(entry.displayTitle) { browser.newTab(url: entry.url, in: entry.profileID) }
                }
            }
        }
    }
}

private struct BrowserCommands: Commands {
    let settings: SettingsStore
    @FocusedValue(\.focusAddressBar) private var focusAddressBar
    @FocusedValue(\.focusAssistant) private var focusAssistant
    @FocusedValue(\.toggleAgentPanel) private var toggleAgentPanel

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location…") { focusAddressBar?.perform() }
                .keyboardShortcut("l")
                .disabled(focusAddressBar == nil)
            Button("Ask Assistant…") { focusAssistant?.perform() }
                .keyboardShortcut("k")
                .disabled(focusAssistant == nil)
            Button("Toggle Agent Panel") { toggleAgentPanel?.perform() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(toggleAgentPanel == nil)

            Divider()

            @Bindable var settings = settings
            Picker("Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
        }
    }
}
