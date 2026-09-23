import Foundation
import Observation
import SQLiteData

/// One row per setting, in the database rather than `UserDefaults`, so settings travel with the
/// rest of the data (and can sync: a key is a fine primary key, and a per-column last-write-wins
/// merge on `value` is exactly right for a preference).
@Table("settings")
nonisolated struct Setting: Sendable {
    @Column(primaryKey: true) var key: String
    var value: String
}

/// The window as a row of full-height windows, or as a tab bar over the one page in front — the
/// way every other browser draws it. Two views of one strip, never two strips: a tab is a window, a
/// tab group is a workspace, and its name is the workspace's name.
nonisolated enum InterfaceStyle: String, Sendable, CaseIterable {
    case row
    case tabs
}

/// Typed access to the settings table, cached in memory. Reads are observable; writes hit the
/// database at once.
@MainActor
@Observable
final class ConfigurationStore {
    enum Key: String, CaseIterable {
        case searchEngine = "search.engine"
        /// Whether six's language models and agents run at all. See `isAIEnabled`.
        case aiEnabled = "ai.enabled"
        /// Whether the welcome window has been answered, so it is shown exactly once.
        case welcomeAnswered = "onboarding.welcome"
        case assistantModel = "assistant.model"
        /// The OpenAI-compatible endpoint the assistant talks to, and the model it names there.
        case assistantOpenAIBaseURL = "assistant.openai.baseURL"
        case assistantOpenAIModel = "assistant.openai.model"
        /// The System 1 decision endpoint for page tasks: TypeSafe's Jev, or a local laya-browser
        /// server, which answers the same `/v1/systemone` request. Empty means page tasks are
        /// decided by the assistant's own model alone.
        case pageTaskEndpoint = "pagetask.endpoint"
        case pageTaskModel = "pagetask.model"
        case pageTaskThreshold = "pagetask.threshold"
        case centersFocus = "layout.centersFocus"
        case fill = "layout.fill"
        case peeksAtEdges = "layout.peeksAtEdges"
        /// The row, or a tab bar over one page (`InterfaceStyle`).
        case interfaceStyle = "interface.style"
        case agentModel = "agent.model"
        case agentModels = "agents.models"
        case agentModelCatalogs = "agents.modelCatalogs"
        case customAgents = "agents.custom"
        case selectedCustomAgent = "agents.selectedCustom"
        /// Tool calls answered "always": agent id → tool title → the option kind that answered it.
        case agentStandingAnswers = "agents.standingAnswers"
        case bookmarkScope = "bookmarks.scope"
        case bookmarkRefreshDays = "bookmarks.refreshDays"
        case embeddingModel = "bookmarks.embeddingModel"
        case researchTemplate = "research.template"
        case researchSources = "research.sources"
        case blockingEnabled = "blocking.enabled"
        case blockingLists = "blocking.lists"
        case blockingAllowlist = "blocking.allowlist"
        case blockingRefreshDays = "blocking.refreshDays"
        case installedExtensions = "extensions.installed"
        /// The one installed extension allowed to replace the start page with its own new-tab page
        /// (`WKWebExtension.hasOverrideNewTabPage`) — Apple's own note says to ask before using it, so
        /// this is the record of having asked, not a capability WebKit hands out on its own.
        case newTabOverride = "extensions.newTabOverride"
        case devToolsInspector = "devtools.inspector"
        case devToolsCapture = "devtools.capture"
        case sitePermissions = "permissions.sites"
        /// The default profile's identifier. On the Mac profiles live in the state snapshot; a front
        /// that has no snapshot yet still needs the id to be the same one tomorrow, or every launch
        /// orphans its own history.
        case defaultProfile = "profile.default"
        /// The profile that was on screen when six was last closed. Distinct from `defaultProfile`
        /// above, which is a front *without* a profiles table inventing an id to key its history by;
        /// this one names a row that exists. On the Mac it lives in the state snapshot, the way
        /// `stripState` below does, and for the same reason a front without a snapshot keeps it here.
        /// A private profile is never written: it is not in the table, and coming back into one
        /// after a relaunch would be a private session that outlived the process.
        case selectedProfile = "profile.selected"
        /// What pages are translated into, and the sites translated without being asked (a JSON
        /// array of hosts).
        case translationTarget = "translation.target"
        case translationHosts = "translation.hosts"
        /// MCP app servers handed to the agent through `six --mcp` (a JSON array of server ids).
        case mcpSharedServers = "mcpApps.shared"
        /// The servers the user added (a JSON array of `MCPServerDefinition`).
        case mcpCustomServers = "mcpApps.servers"
        /// The strip as it was left: workspaces, columns, and the address each column was on.
        /// On the Mac this lives in the state snapshot beside the database; a front without one
        /// keeps it here, where it is migrated and backed up with everything else.
        case stripState = "strip.state"
        /// The certificate bundles six trusts on top of the system's, by id (a JSON array). Empty
        /// until somebody switches one on; see `CertificateStore`.
        case trustedCertificates = "trust.certificates"
        /// Whether six has already switched its own share extension on for this person. Written once
        /// and never read as a capability: it is the record of an offer made, so that a person who
        /// switches it back off is not overruled at the next launch (`ShareExtensionSwitch`).
        case shareExtensionOffered = "sharing.extensionOffered"
    }

    /// The app's instance, for the few static call sites (`SearchEngine.current`). Set at launch.
    static var shared: ConfigurationStore?

    @ObservationIgnored private let database: any DatabaseWriter
    private var values: [String: String] = [:]

    init(database: any DatabaseWriter) {
        self.database = database
        do {
            let rows = try database.read { db in try Setting.all.fetchAll(db) }
            values = Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        } catch {
            Log.error(.storage, "settings load failed: \(error)")
        }
    }

    // MARK: Typed settings

    /// Centre the focused column; on by default.
    var centersFocus: Bool {
        get { self[.centersFocus].map { $0 == "1" } ?? true }
        set { self[.centersFocus] = newValue ? "1" : "0" }
    }

    /// Tiled or full-window, whichever the user last chose — so an empty workspace losing its last
    /// window and being rebuilt fresh does not quietly answer this itself. Full window until anyone
    /// has chosen otherwise.
    var fill: TilingFill {
        get { self[.fill].flatMap(TilingFill.init(rawValue:)) ?? .window }
        set { self[.fill] = newValue.rawValue }
    }

    /// Whether the strip's edge buttons wait to be found or stand on the screen. A peek is a pointer
    /// idea: it is asked for by resting somewhere, and answered by the strip leaning over. A finger
    /// has nowhere to rest — it is either touching or not — so on a touch screen the buttons are drawn
    /// where they are and do their job on the way in, the way they did before the peek existed.
    var peeksAtEdges: Bool {
        get { self[.peeksAtEdges].map { $0 == "1" } ?? Self.peeksByDefault }
        set { self[.peeksAtEdges] = newValue ? "1" : "0" }
    }

    /// Which of the two faces the window wears. Nothing in the strip depends on it: the tabs are the
    /// row's windows and their groups are its workspaces, so switching back and forth loses nothing.
    /// Tabs until anyone has chosen otherwise: it is the face a person arriving from another browser
    /// already knows, and the row is one switch away.
    var interfaceStyle: InterfaceStyle {
        get { self[.interfaceStyle].flatMap(InterfaceStyle.init(rawValue:)) ?? .tabs }
        set { self[.interfaceStyle] = newValue.rawValue }
    }

    #if os(macOS)
    static let peeksByDefault = true
    #else
    static let peeksByDefault = false
    #endif

    /// Where the fast decider for page tasks lives, and which model to ask it for. Both are
    /// addresses rather than secrets, so they live here; the key sits beside the other keys in
    /// `AssistantSettings`.
    var pageTaskEndpoint: String {
        get { self[.pageTaskEndpoint] ?? "" }
        set { self[.pageTaskEndpoint] = newValue.isEmpty ? nil : newValue }
    }

    var pageTaskModel: String {
        get { self[.pageTaskModel] ?? "" }
        set { self[.pageTaskModel] = newValue.isEmpty ? nil : newValue }
    }

    /// Below this probability a step is re-decided by the assistant's model instead. 0.9 out of the
    /// box: laya-browser's own held-out element accuracy is 0.63, so most steps of a hard page
    /// should go up, and the cheap decider should keep the ones it is sure of.
    var pageTaskThreshold: Double {
        get { self[.pageTaskThreshold].flatMap(Double.init) ?? 0.9 }
        set { self[.pageTaskThreshold] = String(max(0, min(1, newValue))) }
    }

    /// The deep-research preset as edited by the user; empty means the built-in one.
    var researchTemplate: String {
        get { self[.researchTemplate] ?? "" }
        set { self[.researchTemplate] = newValue.isEmpty ? nil : newValue }
    }

    /// How often a saved page is re-read from its site and re-embedded if it changed; 0 is never.
    var bookmarkRefreshDays: Int {
        get { self[.bookmarkRefreshDays].flatMap(Int.init) ?? 7 }
        set { self[.bookmarkRefreshDays] = String(newValue) }
    }

    /// Ad and tracker blocking, on out of the box. Off means off: no lists fetched, nothing
    /// compiled, no rules attached — the switch is there for people who bring their own blocker.
    /// The one switch over everything in six that talks to a language model or an agent: the ⌘E
    /// line and its verbs, the bar over a selection **and the script that watches for one**, the
    /// agent panel and ACP, deep research, and six's own MCP server. Off is not a greyed-out button
    /// — none of it is built, nothing is injected into a page, and no socket is listening.
    ///
    /// What is deliberately *not* under it: the on-device bookmark index and page translation.
    /// Neither is a model talking to a person — one is how search finds a page you read in another
    /// language, the other is what every browser has had for a decade — and switching them off with
    /// the assistant would take away search and the translate button for a reason nobody asked for.
    ///
    /// On by default, and the welcome window asks on the first launch (`WelcomePage`).
    var isAIEnabled: Bool {
        get { self[.aiEnabled].map { $0 == "1" } ?? true }
        set { self[.aiEnabled] = newValue ? "1" : "0" }
    }

    /// Has six already switched its share extension on once? See `ShareExtensionSwitch` for why once.
    var hasOfferedShareExtension: Bool {
        get { self[.shareExtensionOffered] == "1" }
        set { self[.shareExtensionOffered] = newValue ? "1" : "0" }
    }

    /// Has the welcome window been answered? Until it has, it is what six opens with.
    var hasAnsweredWelcome: Bool {
        get { self[.welcomeAnswered] == "1" }
        set { self[.welcomeAnswered] = newValue ? "1" : "0" }
    }

    var blockingEnabled: Bool {
        get { self[.blockingEnabled].map { $0 == "1" } ?? true }
        set { self[.blockingEnabled] = newValue ? "1" : "0" }
    }

    /// Sites the user asked six to leave alone, as bare hostnames.
    var blockingAllowlist: [String] {
        get { decode(.blockingAllowlist) ?? [] }
        set { encode(.blockingAllowlist, newValue) }
    }

    /// MCP app servers whose tools six passes on to the agent (see docs/mcp-apps.md). Empty by
    /// default: connecting to a server means launching a process, and that is the user's call.
    var mcpSharedServers: [String] {
        get { decode(.mcpSharedServers) ?? [] }
        set { encode(.mcpSharedServers, newValue) }
    }

    /// The MCP servers the user added, as the JSON text they were stored as.
    ///
    /// A string rather than the typed value on purpose: this file is one of the ones that has to
    /// compile on Linux with nothing but Foundation (see `Package.swift`), and `MCPServerDefinition`
    /// belongs to the Mac app. `MCPAppStore` owns the shape; the settings table only keeps it.
    var mcpCustomServers: String {
        get { self[.mcpCustomServers] ?? "" }
        set { self[.mcpCustomServers] = newValue.isEmpty ? nil : newValue }
    }

    /// How often filter lists are fetched again; 0 is never (what is on disk keeps blocking).
    var blockingRefreshDays: Int {
        get { self[.blockingRefreshDays].flatMap(Int.init) ?? 3 }
        set { self[.blockingRefreshDays] = String(newValue) }
    }

    /// Web Inspector: Safari's Develop menu can attach to six's pages. Off by default — an
    /// inspectable page is one another process on the machine can attach to.
    var devToolsInspector: Bool {
        get { self[.devToolsInspector].map { $0 == "1" } ?? false }
        set { self[.devToolsInspector] = newValue ? "1" : "0" }
    }

    /// Console and network capture, for the agent tools. Off by default: it runs a hook in the
    /// page's own world (`PageInstrumentation`).
    var devToolsCapture: Bool {
        get { self[.devToolsCapture].map { $0 == "1" } ?? false }
        set { self[.devToolsCapture] = newValue ? "1" : "0" }
    }

    /// The installed extension id (if any) allowed to stand in for the start page on a blank new
    /// window. `nil` until the user turns one on in `ExtensionsView`; uninstalling it does not
    /// un-set this by itself, so `ExtensionStore.overrideNewTabPageURL(for:)` checks that the
    /// extension is still installed, enabled, and still declares the capability.
    var newTabOverrideExtensionID: String? {
        get { self[.newTabOverride] }
        set { self[.newTabOverride] = newValue }
    }

    /// The profile a front uses when it has no other. Made once and kept, so history and cookies
    /// belong to the same profile across launches.
    ///
    /// Stored as `uuidString`, which is uppercase, while GRDB writes the `visits` column lowercase.
    /// Nothing compares them as text — `UUID(uuidString:)` reads either — but a hand-written SQL
    /// query joining the two will find nothing, which is worth knowing before it wastes an hour.
    var defaultProfileID: UUID {
        if let stored = self[.defaultProfile], let id = UUID(uuidString: stored) { return id }
        let fresh = UUID()
        self[.defaultProfile] = fresh.uuidString
        return fresh
    }

    /// The profile that was last on screen, or nil on a first launch — and nil, deliberately, for an
    /// id that no longer names a row, so that a profile deleted elsewhere does not strand the browser
    /// on nothing. Unlike `defaultProfileID` this mints nothing: not knowing is an answer here.
    var selectedProfileID: UUID? {
        get { self[.selectedProfile].flatMap(UUID.init(uuidString:)) }
        set { self[.selectedProfile] = newValue?.uuidString }
    }

    /// Optional model id for the ACP agent (`ANTHROPIC_MODEL`).
    var agentModel: String {
        get { self[.agentModel] ?? "" }
        set { self[.agentModel] = newValue }
    }

    // MARK: Codable values

    /// Four of these settings are a JSON document rather than a scalar, and were the same eight
    /// lines four times over. The accessors that use them live beside the types they decode.
    func decode<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        guard let json = self[key], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `keepingEmpty: false` deletes the row instead of storing `[]` — for a setting whose absence
    /// and whose empty value mean the same thing, and which is better off not taking up a row.
    func encode(_ key: Key, _ value: some Collection & Encodable, keepingEmpty: Bool = true) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if value.isEmpty, !keepingEmpty {
            self[key] = nil
        } else {
            self[key] = String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: Raw access

    subscript(key: Key) -> String? {
        get { values[key.rawValue] }
        set {
            guard values[key.rawValue] != newValue else { return }
            values[key.rawValue] = newValue
            do {
                try database.write { db in
                    if let newValue {
                        // `upsert`, not `insert`. A plain insert is only ever right the first time a
                        // key is written, and every change after that failed on the primary key —
                        // *"UNIQUE constraint failed: settings.key"*, caught, printed to stderr and
                        // stepped over. The in-memory cache took the new value, so nothing looked
                        // wrong until the next launch read the old one back.
                        //
                        // Found on Linux, answering a site's request for the camera and the
                        // microphone: the second of the two answers never reached the table.
                        try Setting.upsert { Setting(key: key.rawValue, value: newValue) }.execute(db)
                    } else {
                        try Setting.where { $0.key.eq(key.rawValue) }.delete().execute(db)
                    }
                }
            } catch {
                Log.error(.storage, "settings save failed: \(error)")
            }
        }
    }

}
