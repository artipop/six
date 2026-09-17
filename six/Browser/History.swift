import Foundation
import Observation
import SQLiteData

/// One visit. History is per profile, like everything else the profile isolates.
@Table("visits")
nonisolated struct Visit: Identifiable, Sendable, Hashable {
    let id: UUID
    var profileID: UUID
    var url: URL
    var title = ""
    var visitedAt: Date

    /// What to call the visit: a search results page is its query, anything else its title (or address).
    var displayTitle: String {
        if let search = SearchEngine.search(from: url) { return search.query }
        return title.isEmpty ? url.absoluteString : title
    }

    /// Where it went: the engine for a search, the host for a page.
    var displayDetail: String {
        if let search = SearchEngine.search(from: url) { return "\(search.engine.title) Search" }
        return url.host() ?? url.absoluteString
    }
}

typealias HistoryEntry = Visit

/// Browsing history for every profile, in the `visits` table. Readers see a `revision` that every
/// write bumps, so a view that reads through this store under observation re-queries on change.
@MainActor
@Observable
final class HistoryStore {
    /// How far back the start page and the search look, per profile. Beyond this the history is
    /// still there, just not in the ranking.
    static let rankingWindow = 5000

    @ObservationIgnored private let database: any DatabaseWriter
    private(set) var revision = 0

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: Writing

    /// A committed navigation. Reloading or re-visiting the page you're already on doesn't stack up.
    func record(_ url: URL, title: String, in profileID: UUID) {
        guard Self.isRecordable(url) else { return }
        write { db in
            let last = try Visit.where { $0.profileID.eq(profileID) }.order { $0.visitedAt.desc() }.limit(1).fetchOne(db)
            if let last, last.url == url {
                try Visit.where { $0.id.eq(last.id) }
                    .update { row in
                        row.visitedAt = Date()
                        if !title.isEmpty { row.title = title }
                    }
                    .execute(db)
            } else {
                try Visit.insert { Visit(id: UUID(), profileID: profileID, url: url, title: title, visitedAt: Date()) }.execute(db)
            }
        }
    }

    /// Titles usually arrive after the navigation commits; update the latest visit of that page.
    func updateTitle(_ title: String, for url: URL, in profileID: UUID) {
        guard !title.isEmpty else { return }
        write { db in
            let latest = Visit.where { $0.profileID.eq(profileID) && $0.url.eq(url) }.order { $0.visitedAt.desc() }.limit(1)
            guard let last = try latest.fetchOne(db) else { return }
            try Visit.where { $0.id.eq(last.id) }.update { $0.title = title }.execute(db)
        }
    }

    func remove(_ id: Visit.ID) {
        write { db in try Visit.where { $0.id.eq(id) }.delete().execute(db) }
    }

    func clear(profileID: UUID) {
        write { db in try Visit.where { $0.profileID.eq(profileID) }.delete().execute(db) }
    }

    // MARK: Reading

    /// Every visit of the profile, newest first.
    func entries(in profileID: UUID) -> [Visit] {
        read { db in try Visit.where { $0.profileID.eq(profileID) }.order { $0.visitedAt.desc() }.fetchAll(db) }
    }

    func count(in profileID: UUID) -> Int {
        read { db in try Visit.where { $0.profileID.eq(profileID) }.count().fetchOne(db) ?? 0 }
    }

    /// The most recent visit per page — what a menu shows.
    func recent(in profileID: UUID, limit: Int) -> [Visit] {
        var seen = Set<URL>()
        var result: [Visit] = []
        for entry in window(profileID, limit: limit * 10) where seen.insert(entry.url).inserted {
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    /// Substring search over title and address. In Swift rather than SQL: SQLite's `LIKE` and
    /// `lower()` only know ASCII, and history is in every language.
    func search(_ query: String, in profileID: UUID) -> [Visit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return entries(in: profileID) }
        return entries(in: profileID).filter { entry in
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Completions for the start page and the address field: pages of this profile matching what is
    /// typed, one row per page, the ones visited often and recently first. A host prefix
    /// (`git` → github.com) or the start of a query you searched before beats a match somewhere in
    /// the middle of a title.
    ///
    /// Matched against what a person *reads*, not against what the database holds. A search is
    /// stored as `duckduckgo.com/?q=%D0%BF%D0%BB…` with no title of its own — DuckDuckGo never sets
    /// one before the results render, and often not after — so a substring test over the raw
    /// address found every Latin query and not a single Cyrillic one. The query is decoded out of the
    /// address (`SearchEngine.search(from:)`) and the address itself percent-decoded before anything
    /// is compared.
    func suggest(_ query: String, in profileID: UUID, limit: Int) -> [Visit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let now = Date()
        var best: [String: (entry: Visit, score: Double)] = [:]
        for entry in window(profileID, limit: Self.rankingWindow) {
            guard let match = Self.match(needle, against: entry) else { continue }
            // Visits decay over a couple of weeks, so a page hammered last month doesn't outrank today's.
            let age = now.timeIntervalSince(entry.visitedAt) / 86_400
            let score = match * (1 + 1 / (1 + age / 14))
            let key = Self.suggestionKey(entry.url)
            if let existing = best[key] {
                // The window is newest first, so the row keeps the latest visit — unless that one
                // never got a title and an older one did.
                let kept = existing.entry.title.isEmpty && !entry.title.isEmpty ? entry : existing.entry
                best[key] = (kept, existing.score + score)
            } else {
                best[key] = (entry, score)
            }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(limit).map(\.entry)
    }

    /// How well `needle` (lowercased, trimmed) matches a visit, or nil when it does not.
    static func match(_ needle: String, against entry: Visit) -> Double? {
        // Under two letters a match "somewhere in the middle" is every page there is.
        let loose = needle.count >= 2
        if let search = SearchEngine.search(from: entry.url) {
            let asked = search.query.lowercased()
            if asked.hasPrefix(needle) { return 3 }
            if startsAWord(needle, in: asked) { return 2 }
            if loose, asked.contains(needle) { return 1 }
            return nil
        }
        let host = (entry.url.host(percentEncoded: false) ?? "").lowercased()
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let shownHost = IDN.displayHost(bareHost).lowercased()
        if bareHost.hasPrefix(needle) || host.hasPrefix(needle) || shownHost.hasPrefix(needle) { return 3 }
        let title = entry.title.lowercased()
        if title.hasPrefix(needle) { return 2 }
        if startsAWord(needle, in: title) { return 1.5 }
        guard loose else { return nil }
        let address = (entry.url.absoluteString.removingPercentEncoding ?? entry.url.absoluteString).lowercased()
        if title.contains(needle) || address.contains(needle) { return 1 }
        return nil
    }

    /// One row per page as a person counts pages: a search is its engine and query, whatever else
    /// the engine added to the address (`&ia=web`, `&t=h_`), and a page is its address without the
    /// fragment — Telegram's web client is one page with a different `#chat` for every chat.
    nonisolated static func suggestionKey(_ url: URL) -> String {
        if let search = SearchEngine.search(from: url) {
            return "search:\(search.engine.rawValue):\(search.query.lowercased())"
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private nonisolated static func startsAWord(_ needle: String, in text: String) -> Bool {
        var from = text.startIndex
        while let range = text.range(of: needle, range: from..<text.endIndex) {
            if range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            from = text.index(after: range.lowerBound)
        }
        return false
    }

    // MARK: Plumbing

    private func window(_ profileID: UUID, limit: Int) -> [Visit] {
        read { db in try Visit.where { $0.profileID.eq(profileID) }.order { $0.visitedAt.desc() }.limit(limit).fetchAll(db) }
    }

    private func read<T>(_ body: (Database) throws -> T) -> T where T: ExpressibleByArrayLiteral {
        _ = revision // observed: any write re-runs the caller
        do { return try database.read(body) } catch {
            Log.error(.history, "read failed: \(error)")
            return []
        }
    }

    private func read(_ body: (Database) throws -> Int) -> Int {
        _ = revision
        do { return try database.read(body) } catch { return 0 }
    }

    private func write(_ body: (Database) throws -> Void) {
        do {
            try database.write(body)
            revision += 1
        } catch {
            Log.error(.history, "write failed: \(error)")
        }
    }

    private static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}
