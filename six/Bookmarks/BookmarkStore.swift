#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto: the same SHA-256, so digests written by an Apple build read back identically.
import Crypto
#endif
import Foundation
import GRDB
import NaturalLanguage
import Observation
import SQLiteData
import WebKit

/// Bookmarks for every profile: the `bookmarks` table, a Markdown copy of each page in the
/// profile's `Bookmarks` folder, and a vector index over the text so the assistant and the agents can search
/// what was saved by meaning. Like `HistoryStore`, a `revision` that every write bumps re-runs
/// views that read through it under observation.
@MainActor
@Observable
final class BookmarkStore {
    /// Passages are cut around this many characters; a paragraph longer than `maxChunk` is split.
    nonisolated static let chunkTarget = 900
    nonisolated static let maxChunk = 1400
    /// Beyond this many passages a page is indexed only in part — and says so in `indexError`.
    nonisolated static let maxChunks = 120
    /// Bump when chunking or pooling changes: every bookmark is then re-embedded on the next launch.
    static let indexVersion = 3
    /// A refresh reloads the page off screen and waits this long at most for it.
    static let refreshTimeout: TimeInterval = 30
    /// How often the due bookmarks are looked for while the app runs.
    static let refreshTick: TimeInterval = 3600

    @ObservationIgnored private let database: any DatabaseWriter
    @ObservationIgnored private(set) var embedder: any Embedder
    /// Makes an embedder for a model the user picked, wired at launch — the store knows what to do
    /// with one, not where the weights are kept.
    @ObservationIgnored var makeEmbedder: ((EmbeddingModelChoice) -> any Embedder)?
    /// Which profile a bookmark belongs to, for its folder. Wired at launch.
    @ObservationIgnored var profile: (Profile.ID) -> Profile? = { _ in nil }
    /// The profile's cookie jar, so a refresh sees the page the way the user does. Wired at launch.
    @ObservationIgnored var dataStore: (Profile) -> WKWebsiteDataStore? = { _ in nil }
    /// Days between refreshes of a page; 0 means never (`SettingsStore.bookmarkRefreshDays`).
    @ObservationIgnored var refreshDays: () -> Int = { 7 }
    private(set) var revision = 0
    /// Bookmarks whose text is being embedded right now.
    private(set) var indexing: Set<Bookmark.ID> = []
    /// Bookmarks whose page is being re-read right now.
    private(set) var refreshing: Set<Bookmark.ID> = []
    @ObservationIgnored private var queue: [Bookmark.ID] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var refreshQueue: [Bookmark.ID] = []
    @ObservationIgnored private var refreshWorker: Task<Void, Never>?
    @ObservationIgnored private var scheduler: Task<Void, Never>?

    /// What the vectors must have been made with to count as indexed.
    var indexSignature: String { "\(embedder.modelID)@\(Self.indexVersion)" }

    /// What the model is doing — downloading, ready, failed — for the bookmarks window.
    private(set) var embedderStatus = ""
    /// The `vec0` table for this embedder's dimension: `bookmark_vec_384`. One table per dimension,
    /// created on first use; the model column keeps different embedders apart inside it.
    @ObservationIgnored private(set) var vectorTable: String

    init(database: any DatabaseWriter, embedder: any Embedder = ContextualEmbedder()) {
        self.database = database
        self.embedder = embedder
        vectorTable = "bookmark_vec_\(embedder.dimension)"
        prepareVectorTable()
        narrateEmbedder()
    }

    /// Switches the model the library is indexed with, and re-indexes it.
    ///
    /// Not a conversion: two models' vectors are never comparable, so the old ones are left exactly
    /// where they are — in the table for their own dimension, under their own model id — and every
    /// bookmark is queued to be embedded again by the new one. Switching back is therefore only as
    /// expensive as embedding again; the weights and the vectors from before are both still on the
    /// disk. The download the new model may need is the bookmarks window's footer to narrate.
    func use(_ choice: EmbeddingModelChoice) {
        guard choice.modelID != embedder.modelID, let made = makeEmbedder?(choice) else { return }
        worker?.cancel()
        worker = nil
        queue.removeAll()
        indexing.removeAll()
        embedder = made
        vectorTable = "bookmark_vec_\(made.dimension)"
        embedderStatus = ""
        prepareVectorTable()
        narrateEmbedder()
        revision += 1
        resumeIndexing()
    }

    /// The `vec0` table for the current embedder's dimension, created if this is the first time six
    /// has seen that dimension.
    private func prepareVectorTable() {
        do {
            try database.write { [vectorTable, embedder] db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS "\(vectorTable)" USING vec0(
                      chunk_id TEXT PRIMARY KEY,
                      profile_id TEXT PARTITION KEY,
                      model TEXT,
                      embedding FLOAT[\(embedder.dimension)] distance_metric=cosine
                    )
                    """)
            }
        } catch {
            FileHandle.standardError.write(Data("[six] vector table failed: \(error)\n".utf8))
        }
    }

    /// Lets the current embedder say what it is doing — downloading, loading, failed — where the
    /// bookmarks window can show it.
    private func narrateEmbedder() {
        guard let mlx = embedder as? MLXEmbedder else { return }
        Task { [weak self] in
            await mlx.setStatusHandler { status in
                Task { @MainActor in self?.embedderStatus = status }
            }
        }
    }

    /// The model an index already on this machine was made with, if there is one.
    ///
    /// What it is for: an install that has been embedding with one model since before the setting
    /// existed keeps it. The recommendation is for a library that has nothing to lose; a download and
    /// a full re-embed is not something an update gets to start on its own.
    nonisolated static func modelOfExistingIndex(in database: any DatabaseReader) -> EmbeddingModelChoice? {
        let signatures = (try? database.read { db in try Bookmark.select(\.embeddingModel).fetchAll(db) }) ?? []
        guard let signature = signatures.first(where: { !$0.isEmpty }) else { return nil }
        return EmbeddingModelChoice.allCases.first { signature.hasPrefix($0.modelID) }
    }

    /// Loads the embedding model before anybody searches with it. The first query of a launch
    /// otherwise waits about three seconds for the weights, and waits for them *after* the debounce,
    /// so the field simply says nothing for that long. Only when there is something to search: on a
    /// profile with no bookmarks the model is a 465 MB download that nothing is going to ask.
    func warmUpEmbedder(in scope: BookmarkScope, profileID: Profile.ID) {
        guard count(in: scope, profileID: profileID) > 0 else { return }
        Task { [embedder] in await embedder.warmUp() }
    }

    /// Finishes what an earlier run left unindexed (and re-embeds after a change of embedder). First
    /// sweeps the vector table: a row whose chunk is gone — a crash between the two deletes, an
    /// older run — is dropped, so the index never outlives the bookmarks.
    func resumeIndexing() {
        sweepOrphanVectors()
        let pending = read { db in
            try Bookmark.where { $0.indexError.is(nil) }.order { $0.createdAt.desc() }.fetchAll(db)
        }.filter { $0.indexedAt == nil || $0.embeddingModel != indexSignature }
        for bookmark in pending { enqueue(bookmark.id) }
    }

    // MARK: Adding and removing

    func bookmark(for url: URL, in profileID: Profile.ID) -> Bookmark? {
        read { db in try Bookmark.where { $0.profileID.eq(profileID) && $0.url.eq(url) }.limit(1).fetchAll(db) }.first
    }

    func isBookmarked(_ tab: BrowserTab) -> Bool {
        guard !tab.showsStartPage, let url = tab.currentURL else { return false }
        return bookmark(for: url, in: tab.profileID) != nil
    }

    /// Saves the window's page: reads it as Markdown, writes the file, records the row, and queues
    /// the embedding. Bookmarking a page again refreshes its copy.
    @discardableResult
    func add(_ tab: BrowserTab) async throws -> Bookmark {
        guard !tab.showsStartPage, let url = tab.currentURL else { throw Failure("Nothing is loaded in this window") }
        guard let profile = profile(tab.profileID) else { throw Failure("Unknown profile") }
        guard !profile.isPrivate else { throw Failure("Private browsing keeps no bookmarks") }
        tab.resumeIfNeeded()
        await Self.waitForLoad(tab)
        let readable = try await ReadablePage.extract(from: tab.page)
        let existing = bookmark(for: url, in: profile.id)
        return try await store(readable, url: url, fallbackTitle: tab.title, profile: profile, existing: existing, refreshed: existing != nil)
    }

    /// Writes the file, the row and the chunks for a page just read, and queues the embedding. Unchanged
    /// text (same hash) on a bookmark that is already indexed keeps its vectors and only stamps the time.
    private func store(_ readable: ReadablePage, url: URL, fallbackTitle: String, profile: Profile, existing: Bookmark?, refreshed: Bool) async throws -> Bookmark {
        let id = existing?.id ?? UUID()
        let title = readable.title.isEmpty ? fallbackTitle : readable.title
        let fileName = existing?.fileName.nonEmpty ?? Self.fileName(for: title, id: id)
        let language = readable.language.nonEmpty ?? ContextualEmbedder.language(of: readable.text).rawValue
        let hash = Self.hash(readable.text)
        let unchanged = existing.map { $0.contentHash == hash && $0.indexedAt != nil && $0.embeddingModel == indexSignature } ?? false
        var bookmark = Bookmark(
            id: id, profileID: profile.id, url: url, title: title, excerpt: readable.excerpt,
            siteName: readable.siteName, imageURL: readable.imageURL, fileName: fileName, language: language,
            characterCount: readable.text.count, createdAt: existing?.createdAt ?? Date(),
            indexedAt: unchanged ? existing?.indexedAt : nil, embeddingModel: unchanged ? indexSignature : "", indexError: nil,
            refreshedAt: refreshed ? Date() : nil, contentHash: hash, refreshError: nil
        )
        if unchanged {
            bookmark.indexError = existing?.indexError
            let saved = bookmark
            try await database.write { db in try Self.upsert(saved, in: db) }
            revision += 1
            return bookmark
        }
        try Self.write(readable, bookmark: bookmark, profile: profile, to: folder(for: profile).appending(path: fileName))
        let table = vectorTable
        let saved = bookmark
        try await database.write { db in
            try Self.upsert(saved, in: db)
            try Self.dropIndex(of: id, from: table, in: db)
            let chunks = Self.chunks(title: title, excerpt: readable.excerpt, text: readable.text)
            for (ord, text) in chunks.enumerated() {
                try BookmarkChunk.insert { BookmarkChunk(id: UUID(), bookmarkID: id, ord: ord, text: text) }.execute(db)
            }
        }
        revision += 1
        enqueue(id)
        return bookmark
    }

    // MARK: Refreshing

    /// Re-reads the page from its site — off screen, with the profile's cookies — and stores what
    /// changed. A page that fails to load keeps its old copy and notes why.
    func refresh(_ id: Bookmark.ID) async {
        guard let bookmark = bookmark(id), let profile = profile(bookmark.profileID) else { return }
        guard !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let readable = try await Self.read(bookmark.url, dataStore: dataStore(profile))
            _ = try await store(readable, url: bookmark.url, fallbackTitle: bookmark.title, profile: profile, existing: bookmark, refreshed: true)
        } catch {
            let message = error.localizedDescription
            let now = Date()
            try? await database.write { db in
                try Bookmark.where { $0.id.eq(id) }.update { row in
                    row.refreshedAt = #bind(now)
                    row.refreshError = #bind(message)
                }.execute(db)
            }
            revision += 1
        }
    }

    /// Everything of the profile (or of everyone), now, regardless of age.
    func refreshAll(in profileID: Profile.ID?) {
        let entries = profileID.map { entries(in: .profile, profileID: $0) } ?? entries(in: .all, profileID: UUID())
        for entry in entries { enqueueRefresh(entry.id) }
    }

    /// Bookmarks older than the refresh interval, oldest first — what the scheduler feeds.
    func refreshDue() {
        let days = refreshDays()
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let due = entries(in: .all, profileID: UUID()).filter { $0.lastReadAt < cutoff }.sorted { $0.lastReadAt < $1.lastReadAt }
        for entry in due { enqueueRefresh(entry.id) }
    }

    /// A first look shortly after launch, then once an hour. Pages are refreshed one at a time, so a
    /// long list takes a while and never floods anyone's site.
    func startRefreshSchedule() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                self?.refreshDue()
                try? await Task.sleep(for: .seconds(Self.refreshTick))
            }
        }
    }

    private func enqueueRefresh(_ id: Bookmark.ID) {
        guard !refreshQueue.contains(id), !refreshing.contains(id) else { return }
        refreshQueue.append(id)
        if refreshWorker == nil { refreshWorker = Task { await drainRefresh() } }
    }

    private func drainRefresh() async {
        defer { refreshWorker = nil }
        while !refreshQueue.isEmpty {
            let id = refreshQueue.removeFirst()
            await refresh(id)
            try? await Task.sleep(for: .seconds(2)) // a breath between sites
        }
    }

    /// Loads the URL in a `WebPage` of its own, waits for the load (and a moment for scripts), extracts.
    private static func read(_ url: URL, dataStore: WKWebsiteDataStore?) async throws -> ReadablePage {
        var configuration = WebPage.Configuration()
        if let dataStore { configuration.websiteDataStore = dataStore }
        configuration.applicationNameForUserAgent = UserAgent.applicationName
        let page = WebPage(configuration: configuration)
        page.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(refreshTimeout)
        try? await Task.sleep(for: .milliseconds(300))
        while page.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !page.isLoading else { throw Failure("Timed out loading \(url.host() ?? url.absoluteString)") }
        try? await Task.sleep(for: .seconds(1))
        return try await ReadablePage.extract(from: page)
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func remove(_ id: Bookmark.ID) {
        queue.removeAll { $0 == id } // not yet embedded: never will be
        guard let bookmark = read({ db in try Bookmark.where { $0.id.eq(id) }.fetchAll(db) }).first else { return }
        if let url = fileURL(of: bookmark) { try? FileManager.default.removeItem(at: url) }
        let table = vectorTable
        write { db in
            try Self.dropIndex(of: id, from: table, in: db)
            try Bookmark.where { $0.id.eq(id) }.delete().execute(db)
        }
    }

    /// A profile is going away, and its bookmarks and folder with it.
    func removeAll(in profileID: Profile.ID) {
        let ids = read { db in try Bookmark.where { $0.profileID.eq(profileID) }.select(\.id).fetchAll(db) }
        let table = vectorTable
        write { db in
            for id in ids { try Self.dropIndex(of: id, from: table, in: db) }
            try Bookmark.where { $0.profileID.eq(profileID) }.delete().execute(db)
        }
        if let profile = profile(profileID) { try? FileManager.default.removeItem(at: folder(for: profile)) }
    }

    // MARK: Reading

    func entries(in scope: BookmarkScope, profileID: Profile.ID) -> [Bookmark] {
        read { db in
            switch scope {
            case .profile: try Bookmark.where { $0.profileID.eq(profileID) }.order { $0.createdAt.desc() }.fetchAll(db)
            case .all: try Bookmark.order { $0.createdAt.desc() }.fetchAll(db)
            }
        }
    }

    func count(in profileID: Profile.ID) -> Int {
        _ = revision
        return (try? database.read { db in try Bookmark.where { $0.profileID.eq(profileID) }.count().fetchOne(db) }) ?? 0
    }

    /// How many bookmarks a search in this scope would look at. A count rather than `entries`
    /// because it is asked on a keystroke — `PersonalSuggestions` won't embed a query with nothing
    /// to compare it to, and that is what keeps a field on a fresh install from pulling the model.
    func count(in scope: BookmarkScope, profileID: Profile.ID) -> Int {
        _ = revision
        return (try? database.read { db in
            switch scope {
            case .profile: try Bookmark.where { $0.profileID.eq(profileID) }.count().fetchOne(db)
            case .all: try Bookmark.count().fetchOne(db)
            }
        }) ?? 0
    }

    func bookmark(_ id: Bookmark.ID) -> Bookmark? {
        read { db in try Bookmark.where { $0.id.eq(id) }.fetchAll(db) }.first
    }

    /// A bookmark by id, or by a prefix of it — what an agent has in hand.
    func bookmark(matching raw: String) throws -> Bookmark {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { throw Failure("bookmark_id is required") }
        let matches = entries(in: .all, profileID: UUID()).filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        guard let first = matches.first else { throw Failure("No bookmark with id \(raw); call list_bookmarks or search_bookmarks") }
        guard matches.count == 1 else { throw Failure("Bookmark id \(raw) is ambiguous") }
        return first
    }

    /// The Markdown file, front matter included.
    func content(of bookmark: Bookmark) -> String? {
        guard let url = fileURL(of: bookmark) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func fileURL(of bookmark: Bookmark) -> URL? {
        guard !bookmark.fileName.isEmpty, let profile = profile(bookmark.profileID) else { return nil }
        return folder(for: profile).appending(path: bookmark.fileName)
    }

    /// `~/Library/Application Support/org.deffun.six/Profiles/<name>/Bookmarks`, next to the agents' `Scratchpad`.
    func folder(for profile: Profile) -> URL {
        profile.folder.appending(path: "Bookmarks", directoryHint: .isDirectory)
    }

    // MARK: Search

    /// Hybrid: the query's vector against the index (only the scope's vectors, only the query's
    /// model), merged with substring matches over title, address and excerpt so an exact word still wins
    /// when the model is unavailable or the page hasn't been embedded yet.
    func search(_ query: String, in scope: BookmarkScope, profileID: Profile.ID, limit: Int = 20) async -> [BookmarkHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries(in: scope, profileID: profileID).prefix(limit).map { BookmarkHit(bookmark: $0, score: 0, snippet: $0.excerpt) } }
        var hits: [Bookmark.ID: BookmarkHit] = [:]
        // Text first: cheap, and the fallback when there is no model. Every word of three letters or
        // more has to be there — a stray «в» or "in" must not count as a match.
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }.filter { $0.count >= 3 }
        if !terms.isEmpty {
            for bookmark in entries(in: scope, profileID: profileID) {
                let haystack = (bookmark.title + " " + bookmark.url.absoluteString + " " + bookmark.excerpt).lowercased()
                guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
                hits[bookmark.id] = BookmarkHit(bookmark: bookmark, score: 0.7, snippet: bookmark.excerpt)
            }
        }
        if let vectorHits = try? await vectorSearch(query, in: scope, profileID: profileID, k: limit * 3) {
            for hit in vectorHits {
                if let existing = hits[hit.bookmark.id] {
                    // Both agree: a small nudge over the vector score, so an exact title still wins a tie.
                    hits[hit.bookmark.id] = BookmarkHit(bookmark: hit.bookmark, score: min(1, max(existing.score, hit.score) + 0.03), snippet: hit.snippet)
                } else {
                    hits[hit.bookmark.id] = hit
                }
            }
        }
        return hits.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// A KNN query against the `vec0` table: cosine distance, the query's model only, and the
    /// profile as the partition when scoped — sqlite-vec then never looks at other profiles' rows.
    private func vectorSearch(_ query: String, in scope: BookmarkScope, profileID: Profile.ID, k: Int) async throws -> [BookmarkHit] {
        guard let embedding = try await embedder.embed([query], as: .query).first else { return [] }
        let table = vectorTable
        let blob = Self.blob(embedding.vector)
        let model = embedding.model
        let rows: [(chunkID: UUID, distance: Double)] = try await database.read { db in
            var sql = "SELECT chunk_id, distance FROM \"\(table)\" WHERE embedding MATCH ? AND k = ? AND model = ?"
            var arguments: StatementArguments = [blob, k * 4, model]
            if scope == .profile {
                sql += " AND profile_id = ?"
                arguments += [profileID.uuidString.lowercased()]
            }
            return try Row.fetchAll(db, sql: sql + " ORDER BY distance", arguments: arguments)
                .compactMap { row in UUID(uuidString: row["chunk_id"]).map { ($0, row["distance"] as Double) } }
        }
        guard !rows.isEmpty else { return [] }
        let chunks = try await database.read { db in try BookmarkChunk.where { $0.id.in(rows.map(\.chunkID)) }.fetchAll(db) }
        let byID = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The best passage of each bookmark, up to k bookmarks; rows come back nearest first.
        var best: [Bookmark.ID: (chunk: BookmarkChunk, distance: Double)] = [:]
        for row in rows {
            guard let chunk = byID[row.chunkID], best[chunk.bookmarkID] == nil else { continue }
            best[chunk.bookmarkID] = (chunk, row.distance)
            if best.count == k { break }
        }
        let bookmarks = read { db in try Bookmark.where { $0.id.in(Array(best.keys)) }.fetchAll(db) }
        return bookmarks.compactMap { bookmark in
            guard let match = best[bookmark.id] else { return nil }
            // Cosine similarity: 1 − distance. E5 keeps everything above ~0.7; the ranking is what counts.
            return BookmarkHit(bookmark: bookmark, score: max(0, min(1, 1 - match.distance)), snippet: String(match.chunk.text.prefix(300)))
        }
    }

    // MARK: Indexing

    private func sweepOrphanVectors() {
        let table = vectorTable
        do {
            let removed: Int = try database.write { db in
                let chunkIDs = Set(try BookmarkChunk.select(\.id).fetchAll(db).map { $0.uuidString.lowercased() })
                let stored = try String.fetchAll(db, sql: "SELECT chunk_id FROM \"\(table)\"")
                // Ids are stored lowercase (as SQLiteData writes UUIDs); an upper-case one is from before that.
                let orphans = stored.filter { !chunkIDs.contains($0.lowercased()) || $0 != $0.lowercased() }
                for chunkID in orphans { try db.execute(sql: "DELETE FROM \"\(table)\" WHERE chunk_id = ?", arguments: [chunkID]) }
                return orphans.count
            }
            if removed > 0 { FileHandle.standardError.write(Data("[six] dropped \(removed) orphan vectors\n".utf8)) }
        } catch {
            FileHandle.standardError.write(Data("[six] vector sweep failed: \(error)\n".utf8))
        }
    }

    private func enqueue(_ id: Bookmark.ID) {
        // Being indexed right now is no reason to skip: the page may have been re-saved with new chunks,
        // and the run in flight will notice and leave them to this one.
        guard !queue.contains(id) else { return }
        queue.append(id)
        indexing.insert(id)
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        defer { worker = nil }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            await index(id)
            indexing.remove(id)
        }
    }

    /// Embeds the bookmark's passages and writes them into the vector table under its profile.
    private func index(_ id: Bookmark.ID) async {
        guard let bookmark = bookmark(id) else { return }
        let chunks = read { db in try BookmarkChunk.where { $0.bookmarkID.eq(id) }.order(by: \.ord).fetchAll(db) }
        guard !chunks.isEmpty else { return }
        let modelID = indexSignature
        let profileID = bookmark.profileID
        let now = Date()
        let started = ContinuousClock.now
        do {
            let embeddings = try await embedder.embed(chunks.map(\.text), as: .passage)
            // The model can have been switched under this run (`use`), and these vectors are then
            // from the old space: the new embedder has already queued this bookmark for itself, so
            // the honest thing is to drop them rather than stamp the row with a model it is not on.
            guard modelID == indexSignature else { return }
            let elapsed = ContinuousClock.now - started
            FileHandle.standardError.write(Data("[six] embedded \(chunks.count) passages of \(bookmark.displayTitle) in \(elapsed)\n".utf8))
            let table = vectorTable
            try await database.write { db in
                // Seconds have passed: the bookmark may be gone, or re-saved with new chunks. Only what
                // is still in the tables gets a vector, in the same transaction that checks.
                let live = Set(try BookmarkChunk.where { $0.bookmarkID.eq(id) }.select(\.id).fetchAll(db))
                guard try Bookmark.where({ $0.id.eq(id) }).count().fetchOne(db) ?? 0 > 0, !live.isEmpty else { return }
                try Self.dropVectors(of: chunks.map(\.id), from: table, in: db)
                for (chunk, embedding) in zip(chunks, embeddings) where live.contains(chunk.id) {
                    try db.execute(
                        sql: "INSERT INTO \"\(table)\"(chunk_id, profile_id, model, embedding) VALUES (?, ?, ?, ?)",
                        arguments: [chunk.id.uuidString.lowercased(), profileID.uuidString.lowercased(), embedding.model, Self.blob(embedding.vector)]
                    )
                }
                guard live == Set(chunks.map(\.id)) else { return } // re-saved meanwhile: the new chunks are queued on their own
                let note: String? = chunks.count >= Self.maxChunks ? "Indexed the first \(Self.maxChunks) passages only" : nil
                try Bookmark.where { $0.id.eq(id) }.update { row in
                    row.indexedAt = #bind(now)
                    row.embeddingModel = modelID
                    row.indexError = #bind(note)
                }.execute(db)
            }
        } catch {
            let message = error.localizedDescription
            try? await database.write { db in
                try Bookmark.where { $0.id.eq(id) }.update { $0.indexError = #bind(message) }.execute(db)
            }
            FileHandle.standardError.write(Data("[six] bookmark index failed for \(bookmark.url): \(message)\n".utf8))
        }
        revision += 1
    }

    /// The table's `ON CONFLICT REPLACE` sits on `NOT NULL`, not on the key, so a re-save is delete + insert.
    nonisolated private static func upsert(_ bookmark: Bookmark, in db: Database) throws {
        try Bookmark.where { $0.id.eq(bookmark.id) }.delete().execute(db)
        try Bookmark.insert { bookmark }.execute(db)
    }

    /// Everything the index holds for a bookmark: its chunks and their vectors.
    nonisolated private static func dropIndex(of id: Bookmark.ID, from table: String, in db: Database) throws {
        let chunkIDs = try BookmarkChunk.where { $0.bookmarkID.eq(id) }.select(\.id).fetchAll(db)
        try dropVectors(of: chunkIDs, from: table, in: db)
        try BookmarkChunk.where { $0.bookmarkID.eq(id) }.delete().execute(db)
    }

    nonisolated private static func dropVectors(of chunkIDs: [BookmarkChunk.ID], from table: String, in db: Database) throws {
        for chunkID in chunkIDs {
            try db.execute(sql: "DELETE FROM \"\(table)\" WHERE chunk_id = ?", arguments: [chunkID.uuidString.lowercased()])
        }
    }

    /// Title and excerpt first, then the text in paragraph-sized passages.
    nonisolated static func chunks(title: String, excerpt: String, text: String) -> [String] {
        var result: [String] = []
        let head = [title, excerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        if !head.isEmpty { result.append(head) }
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if current.count + paragraph.count > chunkTarget, !current.isEmpty { flush() }
            if paragraph.count > maxChunk {
                flush()
                for piece in split(paragraph, every: maxChunk) { result.append(piece) }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
            if result.count >= maxChunks { break }
        }
        flush()
        return Array(result.prefix(maxChunks))
    }

    /// Cuts at sentence ends where it can, hard where it must.
    nonisolated private static func split(_ text: String, every limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { ".!?\n".contains($0) }).map { window.index(after: $0) } ?? window.endIndex
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    nonisolated static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Files

    /// `<title slug>-<first 8 of the id>.md`, ASCII-folded so it is the same on any file system.
    nonisolated static func fileName(for title: String, id: UUID) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { slug.append(Character(scalar)) }
            else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 60 { slug = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        let short = String(id.uuidString.prefix(8)).lowercased()
        return (slug.isEmpty ? short : "\(slug)-\(short)") + ".md"
    }

    /// Markdown with YAML front matter — readable in any editor, and enough to rebuild the row.
    nonisolated private static func write(_ page: ReadablePage, bookmark: Bookmark, profile: Profile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var lines = ["---", "title: \(quoted(bookmark.title))", "url: \(bookmark.url.absoluteString)", "site: \(quoted(bookmark.siteName))"]
        if !page.byline.isEmpty { lines.append("author: \(quoted(page.byline))") }
        if let image = bookmark.imageURL { lines.append("image: \(image.absoluteString)") }
        if !bookmark.language.isEmpty { lines.append("language: \(bookmark.language)") }
        lines.append("profile: \(quoted(profile.name))")
        lines.append("saved: \(ISO8601DateFormatter().string(from: bookmark.createdAt))")
        lines.append("id: \(bookmark.id.uuidString)")
        lines.append("---")
        lines.append("")
        if !bookmark.title.isEmpty, !page.markdown.hasPrefix("# ") { lines.append("# \(bookmark.title)"); lines.append("") }
        lines.append(page.markdown)
        lines.append("")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Plumbing

    struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func read<T>(_ body: (Database) throws -> [T]) -> [T] {
        _ = revision
        do { return try database.read(body) } catch {
            FileHandle.standardError.write(Data("[six] bookmarks read failed: \(error)\n".utf8))
            return []
        }
    }

    private func write(_ body: (Database) throws -> Void) {
        do {
            try database.write(body)
            revision += 1
        } catch {
            FileHandle.standardError.write(Data("[six] bookmarks write failed: \(error)\n".utf8))
        }
    }

    private static func waitForLoad(_ tab: BrowserTab, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while tab.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
