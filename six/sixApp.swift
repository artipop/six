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
    @State private var pageFocus: PageFocusStore
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
    @State private var certificates: CertificateStore
    #if os(macOS)
    /// For File › Open Location… — the caret in the address field belongs to whichever window has
    /// the focus, so the menu reaches it across the scene like every other panel does.
    @FocusedValue(\.focusAddressBar) private var focusAddressBar
    #endif

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
        // The profiles live here now, not in the snapshot beside it: they are the identity the
        // visits, the bookmarks and every cookie jar are keyed by (`ProfileStore`).
        let profileStore = ProfileStore(database: database)
        // Built before the browser, and handed to it: `BrowserState.init` builds and loads the
        // windows it restores, and a page is built once with what it was given.
        let pageControllers = PageControllers()
        let blocker = ContentBlocker(settings: settings, controllers: pageControllers)
        let devTools = DevToolsStore(settings: settings, controllers: pageControllers)
        // Built before the browser for the same reason as the blocker: a restored window can ask for
        // the camera the moment it loads, and a question with nowhere to go is answered no.
        let permissions = SitePermissions(settings: settings)
        // And before the browser for the third time: a restored window starts loading the moment it
        // is built, and a site under an anchor the user switched on must not miss its first handshake.
        let certificates = CertificateStore(settings: settings)
        CertificateStore.shared = certificates
        let browser = BrowserState(snapshot: snapshot?.browser, history: history, settings: settings,
                                   profileStore: profileStore, pageControllers: pageControllers,
                                   blocker: blocker, devTools: devTools, permissions: permissions)
        permissions.isPrivate = { [weak browser] id in browser?.isPrivate(id) ?? false }
        blocker.startRefreshSchedule()
        devTools.browser = browser
        // Decided once and written down: what this Mac is offered, unless an index is already here
        // (then it is what that index was made with), unless the user has said otherwise (then it is
        // that). Never re-decided at a later launch — see `SettingsStore.embeddingModel`.
        let models = AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
        let embedding = settings.embeddingModel ?? BookmarkStore.modelOfExistingIndex(in: database) ?? .recommended
        settings.embeddingModel = embedding
        let bookmarks = BookmarkStore(database: database, embedder: MLXEmbedder(choice: embedding, modelsDirectory: models))
        bookmarks.makeEmbedder = { MLXEmbedder(choice: $0, modelsDirectory: models) }
        bookmarks.profile = { [weak browser] id in browser?.profiles.first { $0.id == id } }
        bookmarks.dataStore = { [weak browser] profile in browser?.dataStore(for: profile) }
        bookmarks.refreshDays = { [weak settings] in settings?.bookmarkRefreshDays ?? 7 }
        bookmarks.startRefreshSchedule()
        browser.bookmarks = bookmarks
        bookmarks.resumeIndexing()
        // `SIX_EMBED_SWITCH=base` works the model picker from a terminal, three seconds in. It is the
        // one control in Settings that nothing here can click — screenshots and synthetic clicks both
        // need permissions this machine does not give (CLAUDE.md) — and the half it drives is the live
        // one: a new table, a re-index, the old vectors left where they are. The setting is not
        // written, so a restart is back to whatever the user chose.
        if let switchTo = ProcessInfo.processInfo.environment["SIX_EMBED_SWITCH"].flatMap(EmbeddingModelChoice.init(rawValue:)) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                FileHandle.standardError.write(Data("[six] embed: switching to \(switchTo.rawValue)\n".utf8))
                bookmarks.use(switchTo)
            }
        }
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
        // What the pages have under the cursor. Built with the controllers, like the blocker and
        // devtools, because a window restored at launch starts loading before anything asks.
        let pageFocus = PageFocusStore(controllers: pageControllers)
        assistant.focus = pageFocus
        browser.pageFocus = pageFocus
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
        // And back the other way, which is the only thing the store knows about the socket: when
        // what the agent would be given changes, whoever is connected has to be told, because it
        // asked for the list once and would otherwise keep the old one until the next launch.
        mcpApps.onSharedServersChanged = { [weak mcp] in mcp?.toolsChanged() }
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
        _pageFocus = State(initialValue: pageFocus)
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
        _certificates = State(initialValue: certificates)
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
                .environment(pageFocus)
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
                .environment(certificates)
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
            // ⌘, opens `six://settings` in a column, like any other address — see `SettingsPageView`
            // for why settings are a page and not a window. `CommandGroup(replacing:)` rather than a
            // Button of our own, so it lands where macOS puts Settings in every other app.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { browser.openBuiltIn(.settings) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Window on the Rail") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("Reopen Closed Window") { browser.reopenClosedWindow() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!browser.canReopenClosedWindow)
                Button("New Private Window") { browser.newPrivateWindow() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Close Private Browsing") { browser.closePrivateBrowsing() }
                    .disabled(browser.privateProfile == nil)
                Button("Close Window") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
                Divider()
                // Safari's home for it, and the only menu that already means "an address".
                Button("Open Location…") { focusAddressBar?.perform() }
                    .keyboardShortcut("l")
                    .disabled(focusAddressBar == nil)
            }
            // The Edit menu's own group, next to Copy, because this is the same verb aimed at the
            // window instead of at the selection. The key is answered by `KeyBindings` before the
            // menu bar is ever asked — a focused `WKWebView` would otherwise get there first — so
            // the item is here to be found and to be clicked.
            CommandGroup(after: .pasteboard) {
                Button("Copy Address") { browser.copyAddress() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            FileCommands(browser: browser, highlights: highlights)
            ViewCommands(browser: browser)
            HistoryCommands(browser: browser)
            BookmarkCommands(browser: browser, bookmarks: bookmarks)
            AppCommands(browser: browser, apps: mcpApps)
        }
        #elseif os(iOS)
        // A `WindowGroup`, because that is the only scene a phone has; it still comes up as one
        // window, for the same reason the Mac insists on one — the pages are live `WebPage`s and a
        // second `WebView` over the same one traps in WebKit.
        WindowGroup {
            PhoneContentView()
                .environment(browser)
                .environment(assistant)
                .environment(pageFocus)
                .environment(settings)
                .environment(bookmarks)
                .environment(highlights)
                .environment(blocker)
                .environment(extensions)
                .environment(devTools)
                .environment(permissions)
                .environment(certificates)
                .onOpenURL { url in browser.newTab(url: url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    browser.newTab(url: url)
                }
        }
        #endif
    }
}
