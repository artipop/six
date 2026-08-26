import Foundation
import Observation

/// One visit. History is per profile, like everything else the profile isolates.
nonisolated struct HistoryEntry: Codable, Identifiable, Sendable, Hashable {
    var id = UUID()
    var profileID: UUID
    var url: URL
    var title: String
    var visitedAt: Date
}

/// What `history.json` holds.
nonisolated struct HistorySnapshot: VersionedSnapshot {
    static let currentVersion = 1
    var version = HistorySnapshot.currentVersion
    var entries: [HistoryEntry]
}

/// Browsing history for every profile, newest first. Kept apart from the app-state snapshot: it is
/// bigger, changes on every page, and losing it is no tragedy.
@MainActor
@Observable
final class HistoryStore {
    static let capacity = 5000

    private(set) var entries: [HistoryEntry] = []

    init(snapshot: HistorySnapshot? = nil) {
        entries = snapshot?.entries ?? []
    }

    var snapshot: HistorySnapshot { HistorySnapshot(entries: entries) }

    /// A committed navigation. Reloading or re-visiting the page you're already on doesn't stack up.
    func record(_ url: URL, title: String, in profileID: UUID) {
        guard Self.isRecordable(url) else { return }
        if let last = entries.first(where: { $0.profileID == profileID }), last.url == url {
            if let index = entries.firstIndex(where: { $0.id == last.id }) {
                entries[index].visitedAt = Date()
                if !title.isEmpty { entries[index].title = title }
            }
            return
        }
        entries.insert(HistoryEntry(profileID: profileID, url: url, title: title, visitedAt: Date()), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// Titles usually arrive after the navigation commits; update the latest visit of that page.
    func updateTitle(_ title: String, for url: URL, in profileID: UUID) {
        guard !title.isEmpty,
              let index = entries.firstIndex(where: { $0.profileID == profileID && $0.url == url }) else { return }
        entries[index].title = title
    }

    func entries(in profileID: UUID) -> [HistoryEntry] {
        entries.filter { $0.profileID == profileID }
    }

    /// The most recent visit per page — what a menu shows.
    func recent(in profileID: UUID, limit: Int) -> [HistoryEntry] {
        var seen = Set<URL>()
        var result: [HistoryEntry] = []
        for entry in entries where entry.profileID == profileID && seen.insert(entry.url).inserted {
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    func search(_ query: String, in profileID: UUID) -> [HistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !terms.isEmpty else { return entries(in: profileID) }
        return entries.filter { entry in
            guard entry.profileID == profileID else { return false }
            let haystack = (entry.title + " " + entry.url.absoluteString).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Completions for the start page: pages of this profile matching what is typed, one per URL,
    /// the ones visited often and recently first. A host prefix (`git` → github.com) beats a match
    /// somewhere in the middle of a title.
    func suggest(_ query: String, in profileID: UUID, limit: Int) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let now = Date()
        var best: [URL: (entry: HistoryEntry, score: Double)] = [:]
        for entry in entries where entry.profileID == profileID {
            let host = (entry.url.host() ?? "").lowercased()
            let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let title = entry.title.lowercased()
            let address = entry.url.absoluteString.lowercased()
            let match: Double
            if bareHost.hasPrefix(needle) || host.hasPrefix(needle) { match = 3 }
            else if title.hasPrefix(needle) { match = 2 }
            else if title.contains(needle) || address.contains(needle) { match = 1 }
            else { continue }
            // Visits decay over a couple of weeks, so a page hammered last month doesn't outrank today's.
            let age = now.timeIntervalSince(entry.visitedAt) / 86_400
            let score = match * (1 + 1 / (1 + age / 14))
            if let existing = best[entry.url] {
                best[entry.url] = (existing.entry, existing.score + score)
            } else {
                best[entry.url] = (entry, score)
            }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(limit).map(\.entry)
    }

    func remove(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    func clear(profileID: UUID) {
        entries.removeAll { $0.profileID == profileID }
    }

    private static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }
}
