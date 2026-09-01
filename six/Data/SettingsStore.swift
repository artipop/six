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

/// Typed access to the settings table, cached in memory. Reads are observable; writes hit the
/// database at once.
@MainActor
@Observable
final class SettingsStore {
    enum Key: String, CaseIterable {
        case searchEngine = "search.engine"
        case assistantModel = "assistant.model"
        /// The OpenAI-compatible endpoint the assistant talks to, and the model it names there.
        case assistantOpenAIBaseURL = "assistant.openai.baseURL"
        case assistantOpenAIModel = "assistant.openai.model"
        case centersFocus = "layout.centersFocus"
        case peeksAtEdges = "layout.peeksAtEdges"
        case agentModel = "agent.model"
        case bookmarkScope = "bookmarks.scope"
        case bookmarkRefreshDays = "bookmarks.refreshDays"
        case researchTemplate = "research.template"
        case researchSources = "research.sources"
        case livePages = "browser.livePages"
        case blockingEnabled = "blocking.enabled"
        case blockingLists = "blocking.lists"
        case blockingAllowlist = "blocking.allowlist"
        case blockingRefreshDays = "blocking.refreshDays"
        case installedExtensions = "extensions.installed"
        case devToolsInspector = "devtools.inspector"
        case devToolsCapture = "devtools.capture"
        case sitePermissions = "permissions.sites"
        /// The default profile's identifier. On the Mac profiles live in the state snapshot; a front
        /// that has no snapshot yet still needs the id to be the same one tomorrow, or every launch
        /// orphans its own history.
        case defaultProfile = "profile.default"
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
    }

    /// The app's instance, for the few static call sites (`SearchEngine.current`). Set at launch.
    static var shared: SettingsStore?

    @ObservationIgnored private let database: any DatabaseWriter
    private var values: [String: String] = [:]

    init(database: any DatabaseWriter) {
        self.database = database
        do {
            let rows = try database.read { db in try Setting.all.fetchAll(db) }
            values = Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        } catch {
            FileHandle.standardError.write(Data("[six] settings load failed: \(error)\n".utf8))
        }
    }

    // MARK: Typed settings

    /// niri's `center-focused-column`; on by default.
    var centersFocus: Bool {
        get { self[.centersFocus].map { $0 == "1" } ?? true }
        set { self[.centersFocus] = newValue ? "1" : "0" }
    }

    /// Whether the strip's edge buttons wait to be found or stand on the screen. A peek is a pointer
    /// idea: it is asked for by resting somewhere, and answered by the strip leaning over. A finger
    /// has nowhere to rest — it is either touching or not — so on a touch screen the buttons are drawn
    /// where they are and do their job on the way in, the way they did before the peek existed.
    var peeksAtEdges: Bool {
        get { self[.peeksAtEdges].map { $0 == "1" } ?? Self.peeksByDefault }
        set { self[.peeksAtEdges] = newValue ? "1" : "0" }
    }

    #if os(macOS)
    static let peeksByDefault = true
    #else
    static let peeksByDefault = false
    #endif

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
                FileHandle.standardError.write(Data("[six] settings save failed: \(error)\n".utf8))
            }
        }
    }

}
