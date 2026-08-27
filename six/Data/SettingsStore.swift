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

    var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: self[.searchEngine] ?? "") ?? .duckDuckGo }
        set { self[.searchEngine] = newValue.rawValue }
    }

    var assistantModel: ModelChoice {
        get { ModelChoice(rawValue: self[.assistantModel] ?? "") ?? .onDevice }
        set { self[.assistantModel] = newValue.rawValue }
    }

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

    /// What the assistant and the agents search: this profile's bookmarks, or every profile's.
    var bookmarkScope: BookmarkScope {
        get { BookmarkScope(rawValue: self[.bookmarkScope] ?? "") ?? .profile }
        set { self[.bookmarkScope] = newValue.rawValue }
    }

    /// The deep-research preset as edited by the user; empty means the built-in one.
    var researchTemplate: String {
        get { self[.researchTemplate] ?? "" }
        set { self[.researchTemplate] = newValue.isEmpty ? nil : newValue }
    }

    /// How many sources a research run opens.
    var researchSources: Int {
        get { Int(self[.researchSources] ?? "") ?? ResearchPreset.defaultSources }
        set { self[.researchSources] = String(newValue) }
    }

    /// How many windows keep a live `WebPage` at once; the rest are discarded and built again when
    /// they are next shown. Defaults to what the machine's memory can carry (see `LivePageCache`).
    var livePageBudget: Int {
        get { self[.livePages].flatMap(Int.init) ?? LivePageCache.defaultBudget }
        set { self[.livePages] = String(newValue) }
    }

    /// How often a saved page is re-read from its site and re-embedded if it changed; 0 is never.
    var bookmarkRefreshDays: Int {
        get { self[.bookmarkRefreshDays].flatMap(Int.init) ?? 7 }
        set { self[.bookmarkRefreshDays] = String(newValue) }
    }

    /// Optional model id for the ACP agent (`ANTHROPIC_MODEL`).
    var agentModel: String {
        get { self[.agentModel] ?? "" }
        set { self[.agentModel] = newValue }
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
                        try Setting.insert { Setting(key: key.rawValue, value: newValue) }.execute(db)
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
