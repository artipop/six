import SQLiteData
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#endif

/// On the Mac the binary is three things: the browser; with `--mcp`, a stdio MCP server that relays
/// to the running browser (see `MCPStdioBridge`); and with `--mcp-probe`, a client that connects to
/// *someone else's* MCP server and says what it carries (`MCPProbe`, see
/// [mcp-apps.md](../docs/mcp-apps.md)). Both switches happen before AppKit is touched.
/// A phone has no second mode: there is no stdio to serve and no agent process to serve it to.
@main
enum SixMain {
    static func main() {
        #if os(macOS)
        if MCPStdioBridge.isRequested { MCPStdioBridge.run() }
        if MCPProbe.isRequested { MCPProbe.run() }
        if MCPProbe.isCatalogRequested { MCPProbe.runCatalog() }
        signal(SIGPIPE, SIG_IGN) // a vanished MCP client or agent must not kill the app
        #endif
        MainActor.assumeIsolated { sixApp.main() }
    }
}

struct sixApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ExternalOpenDelegate.self) private var externalOpen
    #endif
    @State private var browser: BrowserState
    @State private var assistant: AssistantStore
    #if os(macOS)
    @State private var agentSession: AgentSessionStore
    @State private var mcp: MCPHost
    @State private var mcpApps: MCPAppStore
    #endif
    @State private var settings: SettingsStore
    @State private var bookmarks: BookmarkStore
    @State private var window: WindowState
    @State private var highlights: HighlightStore
    #if os(macOS)
    @State private var research: ResearchCoordinator
    #endif
    @State private var persistence: StatePersistence<FileSnapshotStore<AppStateSnapshot>>
    @State private var blocker: ContentBlocker
    @State private var extensions: ExtensionStore
    @State private var devTools: DevToolsStore
    @State private var permissions: SitePermissions

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
        // Built before the browser, and handed to it: `BrowserState.init` builds and loads the
        // windows it restores, and a page is built once with what it was given.
        let pageControllers = PageControllers()
        let blocker = ContentBlocker(settings: settings, controllers: pageControllers)
        let devTools = DevToolsStore(settings: settings, controllers: pageControllers)
        // Built before the browser for the same reason as the blocker: a restored window can ask for
        // the camera the moment it loads, and a question with nowhere to go is answered no.
        let permissions = SitePermissions(settings: settings)
        let browser = BrowserState(snapshot: snapshot?.browser, history: history, settings: settings,
                                   pageControllers: pageControllers, blocker: blocker, devTools: devTools,
                                   permissions: permissions)
        permissions.isPrivate = { [weak browser] id in browser?.isPrivate(id) ?? false }
        blocker.startRefreshSchedule()
        devTools.browser = browser
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
        let extensions = ExtensionStore(settings: settings)
        extensions.browser = browser
        browser.extensions = extensions
        extensions.start()
        // An extension already installed reaches the restored windows the same way it reaches a new
        // install: the page's configuration is fixed when the page is built.
        if !extensions.installed.filter(\.isEnabled).isEmpty { browser.rebuildLivePages() }
        // A development shortcut: install an unpacked folder at launch, no dialog.
        if let path = ProcessInfo.processInfo.environment["SIX_EXTENSION"], !path.isEmpty {
            Task { await extensions.installFromEnvironment(path) }
        }
        let highlights = HighlightStore()
        highlights.isPrivate = { [weak browser] id in browser?.isPrivate(id) ?? false }
        browser.highlights = highlights
        let assistant = AssistantStore(settings: settings)
        let tools = BrowserToolCatalog(browser: browser, assistant: assistant.settings, bookmarks: bookmarks, settings: settings, highlights: highlights)
        tools.devTools = devTools
        assistant.tools = tools
        #if os(macOS)
        // The agent layer and the MCP server are local processes talking to local processes. The
        // phone has neither, so the assistant there is the language models and nothing else.
        let agentSession = AgentSessionStore(snapshot: snapshot?.agent, settings: settings)
        agentSession.browser = browser
        let research = ResearchCoordinator(browser: browser, agentSession: agentSession, settings: settings)
        assistant.agentSession = agentSession
        assistant.research = research
        let mcp = MCPHost(server: MCPServer(catalog: tools))
        mcp.start()
        // The other direction: six as a host for servers that carry interfaces (docs/mcp-apps.md).
        let mcpApps = MCPAppStore()
        mcpApps.browser = browser
        mcpApps.agent = agentSession
        mcpApps.settings = settings
        // A shared server's tools reach the agent through six's own MCP server, so a call to one
        // lands here and can open a window before it answers.
        mcp.server.apps = mcpApps
        agentSession.appContext = { [weak mcpApps] in mcpApps?.pendingModelContext() ?? [] }
        mcpApps.watchAppearance()
        mcpApps.runSelfTestIfRequested()
        FileHandle.standardError.write(Data("[six] \(mcp.status); state at \(store.url.path)\n".utf8))
        #elseif os(iOS)
        FileHandle.standardError.write(Data("[six] state at \(store.url.path)\n".utf8))
        #endif
        let window = WindowState(snapshot: snapshot?.window)
        // The agent's half of the file is written back untouched where there is no agent, so a phone
        // reading a Mac's state does not throw the transcripts away.
        #if os(macOS)
        let agentSnapshot = { agentSession.snapshot }
        #elseif os(iOS)
        let saved = snapshot?.agent ?? AgentSnapshot(agentID: "", chats: [])
        let agentSnapshot = { saved }
        #endif
        let persistence = StatePersistence(store: store) {
            AppStateSnapshot(browser: browser.snapshot, agent: agentSnapshot(), window: window.snapshot)
        }
        persistence.start()
        #if os(macOS)
        let terminating = NSApplication.willTerminateNotification
        #elseif os(iOS)
        let terminating = UIApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(forName: terminating, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { persistence.flush(); browser.flushDocuments() }
        }
        _settings = State(initialValue: settings)
        _bookmarks = State(initialValue: bookmarks)
        _window = State(initialValue: window)
        _persistence = State(initialValue: persistence)
        _browser = State(initialValue: browser)
        _assistant = State(initialValue: assistant)
        #if os(macOS)
        _agentSession = State(initialValue: agentSession)
        _mcp = State(initialValue: mcp)
        _mcpApps = State(initialValue: mcpApps)
        _research = State(initialValue: research)
        #endif
        _highlights = State(initialValue: highlights)
        _blocker = State(initialValue: blocker)
        _extensions = State(initialValue: extensions)
        _devTools = State(initialValue: devTools)
        _permissions = State(initialValue: permissions)
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
        #if os(macOS)
        // A `Window`, not a `WindowGroup`: six is one window, and the difference is not cosmetic.
        // A group lets SwiftUI answer an external open — a Handoff tile, a link from another app — by
        // building a second window, which puts the same `WebPage`s into a second `WebView`; WebKit
        // traps on that. A `Window` scene has nowhere to build, so SwiftUI raises the one that is up.
        Window("six", id: "main") {
            ContentView()
                .environment(browser)
                .environment(assistant)
                .environment(agentSession)
                .environment(mcp)
                .environment(mcpApps)
                .environment(settings)
                .environment(bookmarks)
                .environment(highlights)
                .environment(research)
                .environment(blocker)
                .environment(extensions)
                .environment(devTools)
                .environment(permissions)
                .background(WindowObserver(state: window))
                // The two doors from outside: a link or file handed to six, and a Handoff tile from an
                // iPhone. macOS delivers through them but leaves the app that was clicked in front,
                // so each one asks for the front afterwards.
                .onOpenURL { url in
                    browser.newTab(url: ExternalOpen.resolve(url))
                    ExternalOpen.comeForward()
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    browser.newTab(url: url)
                    ExternalOpen.comeForward()
                }
                // `"*"` is the wildcard: whatever arrives from outside is this window's.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1500, height: 950)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                // Read once, when the menus are built: if six already holds http/https there is
                // nothing to ask macOS for. A development build never offers at all — it is a second
                // app wearing the same face, and giving it the web would send every link from every
                // other app into a browser that is about to be killed and built again.
                Button("Set six as Default Browser…") {
                    Task { await DefaultBrowser.makeDefault() }
                }
                .disabled(DefaultBrowser.isDefault || AppSupport.isDevelopment)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window in Strip") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("New Private Window") { browser.newPrivateWindow() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Close Private Browsing") { browser.closePrivateBrowsing() }
                    .disabled(browser.privateProfile == nil)
                Button("Close Window") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            FileCommands(browser: browser, highlights: highlights)
            LayoutCommands(browser: browser)
            BrowserCommands(settings: settings)
            PrivacyCommands(browser: browser, blocker: blocker)
            ExtensionCommands(browser: browser, extensions: extensions)
            DevelopCommands(devTools: devTools)
            AppCommands(browser: browser, apps: mcpApps)
            HistoryCommands(browser: browser)
            BookmarkCommands(browser: browser, bookmarks: bookmarks, settings: settings)
        }
        #elseif os(iOS)
        // A `WindowGroup`, because that is the only scene a phone has; it still comes up as one
        // window, for the same reason the Mac insists on one — the pages are live `WebPage`s and a
        // second `WebView` over the same one traps in WebKit.
        WindowGroup {
            PhoneContentView()
                .environment(browser)
                .environment(assistant)
                .environment(settings)
                .environment(bookmarks)
                .environment(highlights)
                .environment(blocker)
                .environment(extensions)
                .environment(devTools)
                .environment(permissions)
                .onOpenURL { url in browser.newTab(url: url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    browser.newTab(url: url)
                }
        }
        #endif
    }
}
