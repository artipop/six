import CryptoKit
import Foundation

/// Where filter lists live on disk, and how they are kept fresh.
///
/// Three files per list under `Application Support/org.deffun.six/Blocking/`: `<id>.txt` — the rules as the
/// publisher wrote them, `<id>.json` — the same rules converted to WebKit's content-blocker JSON
/// (conversion is cheap but not free, and the JSON is what a recompile needs), and one shared
/// `index.json` with what is known about each: its ETag, when it was fetched, how big it came out.
///
/// An actor because all of this is file and network work that has no business on the main thread;
/// `ContentBlocker` is the only caller.
actor FilterListStore {
    struct Entry: Codable, Sendable {
        var etag: String?
        var updatedAt: Date
        /// Of the source text: the compiled rule list is keyed by it, so a list that changed
        /// upstream compiles again and one that didn't is looked up in WebKit's own store.
        var sourceHash: String
        var sourceRules: Int
        var safariRules: Int
        /// What the converter could not express in WebKit's JSON — reported in the panel, not hidden.
        var droppedRules: Int
    }

    static let folder: URL = {
        AppSupport.folder("Blocking")
    }()

    private var index: [String: Entry] = [:]

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexURL),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            index = stored
        }
    }

    private static var indexURL: URL { folder.appending(path: "index.json") }
    private func source(_ id: String) -> URL { Self.folder.appending(path: "\(id).txt") }
    private func json(_ id: String) -> URL { Self.folder.appending(path: "\(id).json") }

    func entry(for id: String) -> Entry? { index[id] }

    /// Fetches the list if it is older than `days` (or `force`), and answers whether the rules
    /// actually changed — an unchanged list is a 304, or the same hash, and costs nothing further.
    func download(_ list: FilterList, olderThan days: Int, force: Bool = false) async throws -> Bool {
        let entry = index[list.id]
        if !force, let entry, FileManager.default.fileExists(atPath: source(list.id).path) {
            let age = Date.now.timeIntervalSince(entry.updatedAt)
            if days <= 0 || age < Double(days) * 86_400 { return false }
        }

        var request = URLRequest(url: list.source)
        request.timeoutInterval = 30
        if let etag = entry?.etag, FileManager.default.fileExists(atPath: source(list.id).path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 304 {
            touch(list.id)
            return false
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let text = String(decoding: data, as: UTF8.self)
        let hash = Self.hash(of: text)
        let unchanged = entry?.sourceHash == hash && FileManager.default.fileExists(atPath: source(list.id).path)
        try text.write(to: source(list.id), atomically: true, encoding: .utf8)
        index[list.id] = Entry(
            etag: http.value(forHTTPHeaderField: "ETag"),
            updatedAt: .now,
            sourceHash: hash,
            sourceRules: entry?.sourceRules ?? 0,
            safariRules: entry?.safariRules ?? 0,
            droppedRules: entry?.droppedRules ?? 0
        )
        save()
        return !unchanged
    }

    /// The converted JSON for a list, converting (and caching it) when the cache is for older rules.
    /// Returns nil when there are no rules on disk at all.
    func safariJSON(for list: FilterList) -> (json: String, hash: String)? {
        guard let text = try? String(contentsOf: source(list.id), encoding: .utf8) else { return nil }
        let hash = Self.hash(of: text)
        if index[list.id]?.sourceHash == hash,
           let cached = try? String(contentsOf: json(list.id), encoding: .utf8), !cached.isEmpty {
            return (cached, hash)
        }
        let started = ContinuousClock.now
        let result = RuleConversion.safariJSON(for: text)
        ContentBlocker.log("converted \(list.id): \(result.sourceRules) rules → \(result.safariRules) Safari rules (\(result.dropped) dropped) in \(started.duration(to: .now))")
        try? result.json.write(to: json(list.id), atomically: true, encoding: .utf8)
        var entry = index[list.id] ?? Entry(etag: nil, updatedAt: .now, sourceHash: hash, sourceRules: 0, safariRules: 0, droppedRules: 0)
        entry.sourceHash = hash
        entry.sourceRules = result.sourceRules
        entry.safariRules = result.safariRules
        entry.droppedRules = result.dropped
        index[list.id] = entry
        save()
        return (result.json, hash)
    }

    /// Everything six knows about a list, forgotten with it.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: source(id))
        try? FileManager.default.removeItem(at: json(id))
        index[id] = nil
        save()
    }

    private func touch(_ id: String) {
        index[id]?.updatedAt = .now
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    static func hash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
