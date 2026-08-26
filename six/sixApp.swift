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
    @State private var browser: BrowserState
    @State private var assistant: AssistantStore
    @State private var agentSession: AgentSessionStore
    @State private var mcp: MCPHost
    @State private var persistence: StatePersistence<FileSnapshotStore<AppStateSnapshot>>
    @State private var historyPersistence: StatePersistence<FileSnapshotStore<HistorySnapshot>>

    init() {
        let store = FileSnapshotStore<AppStateSnapshot>(fileNamed: "state.json")
        let historyStore = FileSnapshotStore<HistorySnapshot>(fileNamed: "history.json")
        let snapshot = Self.load(store)
        let history = HistoryStore(snapshot: Self.load(historyStore))
        let browser = BrowserState(snapshot: snapshot?.browser, history: history)
        let assistant = AssistantStore()
        let agentSession = AgentSessionStore(snapshot: snapshot?.agent)
        agentSession.browser = browser
        let tools = BrowserToolCatalog(browser: browser, assistant: assistant.settings)
        assistant.tools = tools
        assistant.agentSession = agentSession
        let mcp = MCPHost(server: MCPServer(catalog: tools))
        mcp.start()
        FileHandle.standardError.write(Data("[six] \(mcp.status); state at \(store.url.path)\n".utf8))
        let persistence = StatePersistence(store: store) {
            AppStateSnapshot(browser: browser.snapshot, agent: agentSession.snapshot)
        }
        persistence.start()
        let historyPersistence = StatePersistence(store: historyStore) { history.snapshot }
        historyPersistence.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                persistence.flush()
                historyPersistence.flush()
            }
        }
        _persistence = State(initialValue: persistence)
        _historyPersistence = State(initialValue: historyPersistence)
        _browser = State(initialValue: browser)
        _assistant = State(initialValue: assistant)
        _agentSession = State(initialValue: agentSession)
        _mcp = State(initialValue: mcp)
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
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1500, height: 950)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window in Strip") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("Close Window") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            LayoutCommands(browser: browser)
            BrowserCommands()
            HistoryCommands(browser: browser)
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

            Button("Switch Preset Column Width") { browser.cycleColumnWidth() }
                .keyboardShortcut("r", modifiers: .option)
            Button("Compact Width") { browser.toggleCompactWidth() }
                .keyboardShortcut("f", modifiers: .option)
            Button(browser.layout.fill == .window ? "Leave Full Window" : "Full Window") { browser.toggleFullWindow() }
                .keyboardShortcut("w", modifiers: .option)
            Button(browser.layout.fill == .screen ? "Leave Fullscreen" : "Fullscreen") { browser.toggleFullscreen() }
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

private struct BrowserCommands: Commands {
    @AppStorage(SearchEngine.defaultsKey) private var engine: SearchEngine = .duckDuckGo
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

            Picker("Search Engine", selection: $engine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
        }
    }
}
