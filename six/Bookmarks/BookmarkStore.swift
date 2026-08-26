import Accelerate
import Foundation
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
    static let chunkTarget = 900
    static let maxChunk = 1400
    /// Beyond this many passages a page is indexed only in part — and says so in `indexError`.
    static let maxChunks = 120

    @ObservationIgnored private let database: any DatabaseWriter
    @ObservationIgnored let embedder: any Embedder
    /// Which profile a bookmark belongs to, for its folder. Wired at launch.
    @ObservationIgnored var profile: (Profile.ID) -> Profile? = { _ in nil }
    private(set) var revision = 0
    /// Bookmarks whose text is being embedded right now.
    private(set) var indexing: Set<Bookmark.ID> = []
    @ObservationIgnored private var queue: [Bookmark.ID] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(database: any DatabaseWriter, embedder: any Embedder = ContextualEmbedder()) {
        self.database = database
        self.embedder = embedder
    }

    /// Finishes what an earlier run left unindexed (and re-embeds after a change of embedder).
    func resumeIndexing() {
        let pending = read { db in
            try Bookmark.where { $0.indexError.is(nil) }.order { $0.createdAt.desc() }.fetchAll(db)
        }.filter { $0.indexedAt == nil || $0.embeddingModel != embedder.modelID }
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
        tab.resumeIfNeeded()
        await Self.waitForLoad(tab)
        let readable = try await ReadablePage.extract(from: tab.page)
        let existing = bookmark(for: url, in: profile.id)
        let id = existing?.id ?? UUID()
        let createdAt = existing?.createdAt ?? Date()
        let fileName = existing?.fileName.nonEmpty ?? Self.fileName(for: readable.title.isEmpty ? tab.title : readable.title, id: id)
        let title = readable.title.isEmpty ? tab.title : readable.title
        let language = readable.language.nonEmpty ?? ContextualEmbedder.language(of: readable.text).rawValue
        let bookmark = Bookmark(
            id: id, profileID: profile.id, url: url, title: title, excerpt: readable.excerpt,
            siteName: readable.siteName, imageURL: readable.imageURL, fileName: fileName, language: language,
            characterCount: readable.text.count, createdAt: createdAt, indexedAt: nil, embeddingModel: "", indexError: nil
        )
        try Self.write(readable, bookmark: bookmark, profile: profile, to: folder(for: profile).appending(path: fileName))
        try await database.write { db in
            try Bookmark.insert { bookmark }.execute(db)
            try Self.dropIndex(of: id, in: db)
            let chunks = Self.chunks(title: title, excerpt: readable.excerpt, text: readable.text)
            for (ord, text) in chunks.enumerated() {
                try BookmarkChunk.insert { BookmarkChunk(id: UUID(), bookmarkID: id, ord: ord, text: text) }.execute(db)
            }
        }
        revision += 1
        enqueue(id)
        return bookmark
    }

    func remove(_ id: Bookmark.ID) {
        guard let bookmark = read({ db in try Bookmark.where { $0.id.eq(id) }.fetchAll(db) }).first else { return }
        if let url = fileURL(of: bookmark) { try? FileManager.default.removeItem(at: url) }
        write { db in
            try Self.dropIndex(of: id, in: db)
            try Bookmark.where { $0.id.eq(id) }.delete().execute(db)
        }
    }

    /// A profile is going away, and its bookmarks and folder with it.
    func removeAll(in profileID: Profile.ID) {
        let ids = read { db in try Bookmark.where { $0.profileID.eq(profileID) }.select(\.id).fetchAll(db) }
        write { db in
            for id in ids { try Self.dropIndex(of: id, in: db) }
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

    /// `~/Library/Application Support/six/Profiles/<name>/Bookmarks`, next to the agents' `Scratchpad`.
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
        // Text first: cheap, and the fallback when there is no model.
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        for bookmark in entries(in: scope, profileID: profileID) {
            let haystack = (bookmark.title + " " + bookmark.url.absoluteString + " " + bookmark.excerpt).lowercased()
            let matched = terms.filter { haystack.contains($0) }.count
            guard matched > 0 else { continue }
            let score = 0.55 + 0.3 * Double(matched) / Double(terms.count)
            hits[bookmark.id] = BookmarkHit(bookmark: bookmark, score: score, snippet: bookmark.excerpt)
        }
        if let vectorHits = try? await vectorSearch(query, in: scope, profileID: profileID, k: limit * 3) {
            for hit in vectorHits {
                if let existing = hits[hit.bookmark.id] {
                    hits[hit.bookmark.id] = BookmarkHit(bookmark: hit.bookmark, score: min(1, max(existing.score, hit.score) + 0.1), snippet: hit.snippet)
                } else {
                    hits[hit.bookmark.id] = hit
                }
            }
        }
        return hits.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// A brute-force pass: every vector of the query's model (and profile, when scoped) is read and
    /// scored by dot product — the vectors are unit length, so that is the cosine. Fine into the
    /// tens of thousands of passages; an ANN index is the step after that.
    private func vectorSearch(_ query: String, in scope: BookmarkScope, profileID: Profile.ID, k: Int) async throws -> [BookmarkHit] {
        guard let embedding = try await embedder.embed([query]).first else { return [] }
        let model = embedding.model
        let vectors = try await database.read { db in
            switch scope {
            case .profile: try BookmarkVector.where { $0.model.eq(model) && $0.profileID.eq(profileID) }.fetchAll(db)
            case .all: try BookmarkVector.where { $0.model.eq(model) }.fetchAll(db)
            }
        }
        guard !vectors.isEmpty else { return [] }
        let query = embedding.vector
        var scored: [(chunkID: UUID, bookmarkID: UUID, similarity: Double)] = []
        scored.reserveCapacity(vectors.count)
        for vector in vectors {
            guard let similarity = Self.dot(query, vector.embedding) else { continue }
            scored.append((vector.chunkID, vector.bookmarkID, similarity))
        }
        scored.sort { $0.similarity > $1.similarity }
        // The best passage of each bookmark, up to k bookmarks.
        var best: [Bookmark.ID: (chunkID: UUID, similarity: Double)] = [:]
        for entry in scored where best[entry.bookmarkID] == nil {
            best[entry.bookmarkID] = (entry.chunkID, entry.similarity)
            if best.count == k { break }
        }
        let chunkIDs = best.values.map(\.chunkID)
        let chunks = try await database.read { db in try BookmarkChunk.where { $0.id.in(chunkIDs) }.fetchAll(db) }
        let snippets = Dictionary(chunks.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let bookmarks = read { db in try Bookmark.where { $0.id.in(Array(best.keys)) }.fetchAll(db) }
        return bookmarks.compactMap { bookmark in
            guard let match = best[bookmark.id] else { return nil }
            // Cosine similarity −1…1 → 0…1.
            return BookmarkHit(bookmark: bookmark, score: max(0, min(1, (match.similarity + 1) / 2)), snippet: String((snippets[match.chunkID] ?? "").prefix(300)))
        }
    }

    /// Dot product of a query and a stored blob; nil when the blob isn't a vector of the same size.
    nonisolated private static func dot(_ query: [Float], _ blob: Data) -> Double? {
        guard blob.count == query.count * MemoryLayout<Float>.size else { return nil }
        return blob.withUnsafeBytes { raw -> Double in
            let stored = raw.bindMemory(to: Float.self)
            var result: Float = 0
            vDSP_dotpr(query, 1, stored.baseAddress!, 1, &result, vDSP_Length(query.count))
            return Double(result)
        }
    }

    // MARK: Indexing

    private func enqueue(_ id: Bookmark.ID) {
        guard !queue.contains(id), !indexing.contains(id) else { return }
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
        let modelID = embedder.modelID
        let profileID = bookmark.profileID
        let now = Date()
        do {
            let embeddings = try await embedder.embed(chunks.map(\.text))
            try await database.write { db in
                try BookmarkVector.where { $0.bookmarkID.eq(id) }.delete().execute(db)
                for (chunk, embedding) in zip(chunks, embeddings) {
                    try BookmarkVector.insert {
                        BookmarkVector(id: UUID(), chunkID: chunk.id, bookmarkID: id, profileID: profileID, model: embedding.model, embedding: Self.blob(embedding.vector))
                    }.execute(db)
                }
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

    /// Everything the index holds for a bookmark: its chunks and their vectors.
    nonisolated private static func dropIndex(of id: Bookmark.ID, in db: Database) throws {
        try BookmarkVector.where { $0.bookmarkID.eq(id) }.delete().execute(db)
        try BookmarkChunk.where { $0.bookmarkID.eq(id) }.delete().execute(db)
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
        while tab.page.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
