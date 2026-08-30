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
        case centersFocus = "layout.centersFocus"
        case agentModel = "agent.model"
        case columnWidth = "layout.columnWidth"
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
        /// What pages are translated into, and by what. The list of sites translated without being
        /// asked is a JSON array of hosts.
        case translationTarget = "translation.target"
        case translationEngine = "translation.engine"
        case translationHosts = "translation.hosts"
        /// The strip as it was left: workspaces, columns, and the address each column was on.
        /// On the Mac this lives in the state snapshot beside the database; a front without one
        /// keeps it here, where it is migrated and backed up with everything else.
        case stripState = "strip.state"

        /// Where the value lived before the database.
        var legacyDefaultsKey: String {
            switch self {
            case .searchEngine: "six.searchEngine"
            case .assistantModel: "six.assistant.model"
            case .centersFocus: "six.layout.centerFocus"
            case .agentModel: "six.agent.model"
            case .columnWidth: "six.layout.columnWidth"
            case .bookmarkScope: "six.bookmarks.scope"
            case .bookmarkRefreshDays: "six.bookmarks.refreshDays"
            case .researchTemplate: "six.research.template"
            case .researchSources: "six.research.sources"
            case .livePages: "six.browser.livePages"
            case .blockingEnabled: "six.blocking.enabled"
            case .blockingLists: "six.blocking.lists"
            case .blockingAllowlist: "six.blocking.allowlist"
            case .blockingRefreshDays: "six.blocking.refreshDays"
            case .installedExtensions: "six.extensions.installed"
            case .devToolsInspector: "six.devtools.inspector"
            case .devToolsCapture: "six.devtools.capture"
            case .sitePermissions: "six.permissions.sites"
            case .defaultProfile: "six.profile.default"
            case .translationTarget: "six.translation.target"
            case .translationEngine: "six.translation.engine"
            case .translationHosts: "six.translation.hosts"
            case .stripState: "six.strip.state"
            }
        }
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
        importLegacyDefaults()
    }

    // MARK: Typed settings

    /// niri's `center-focused-column`; on by default.
    var centersFocus: Bool {
        get { self[.centersFocus].map { $0 == "1" } ?? true }
        set { self[.centersFocus] = newValue ? "1" : "0" }
    }

    /// Index into `NiriLayout.widthPresets` used by every window.
    var columnWidthIndex: Int {
        get { self[.columnWidth].flatMap(Int.init) ?? NiriLayout.defaultWidthIndex }
        set { self[.columnWidth] = String(newValue) }
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
    var blockingEnabled: Bool {
        get { self[.blockingEnabled].map { $0 == "1" } ?? true }
        set { self[.blockingEnabled] = newValue ? "1" : "0" }
    }

    /// Sites the user asked six to leave alone, as bare hostnames.
    var blockingAllowlist: [String] {
        get { decode(.blockingAllowlist) ?? [] }
        set { encode(.blockingAllowlist, newValue) }
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

    /// First launch with the database: carry the `UserDefaults` values over, once.
    private func importLegacyDefaults() {
        let defaults = UserDefaults.standard
        for key in Key.allCases where values[key.rawValue] == nil {
            guard let stored = defaults.object(forKey: key.legacyDefaultsKey) else { continue }
            switch stored {
            case let string as String: self[key] = string
            case let bool as Bool: self[key] = bool ? "1" : "0"
            default: continue
            }
            defaults.removeObject(forKey: key.legacyDefaultsKey)
        }
    }
}
