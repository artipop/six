import Foundation
import GRDB
import SQLiteData

/// Saving a page and making it findable by meaning, for the fronts that are not the Mac.
///
/// What `BookmarkStore` does, minus the two halves that are Apple's: the off-screen `WKWebView` that
/// re-reads a page, and the Markdown copy written beside it. What is left is the part that decides
/// whether a search works — the row, the passages, the vectors, and the bookkeeping that says which
/// of those are current — and that part has no business being written twice.
///
/// The contract with the Mac is the schema and nothing else, which is what makes this safe: the same
/// `bookmarks` and `bookmark_chunks` rows, the same `TextChunker` cut, the same `bookmark_vec_<n>`
/// table through `VectorIndex`, and the same `<model>@<indexVersion>` stamp in `embeddingModel`. A
/// library saved on Windows is one a Mac reads without noticing, and a Mac that later re-embeds it
/// with a different model does the same thing to it that it would do to its own.
///
/// One serial worker, because the embedder is one page with one wasm heap: two bookmarks embedding
/// at once is the same work in a worse order.
@MainActor
final class BookmarkIndexer {
    private let database: any DatabaseWriter
    /// Which model this index is *for*. It comes from the settings table rather than from the
    /// embedder, and that is what lets the two be separated: the width of the `vec0` table, the
    /// stamp on a row and the name a search filters by are all decided by the choice, and the
    /// embedder is only the thing that fills them in.
    let choice: EmbeddingModelChoice
    /// Nil until a front has a page to run the model in — on Linux and Windows that is after the
    /// window exists. Saving still works meanwhile: the row and its passages are written and left
    /// with `indexedAt` nil, which is exactly what `resumeIndexing` is for.
    private(set) var embedder: (any Embedder)?
    private let index: VectorIndex

    /// Told when a row changes, so a front that draws a list can redraw it. The Mac spends an
    /// `@Observable` revision on this; a front without observation wants a closure.
    var onChange: (() -> Void)?

    /// The folder a profile's things live in — `Profiles/<name>` under `AppSupport` — so a page that
    /// was read can be kept as a Markdown copy in its `Bookmarks/`, where the Mac keeps its own. A
    /// closure because only the front knows how it names a profile's folder; nil keeps no copies.
    var profileFolder: ((UUID) -> URL?)?

    /// Bookmarks whose passages are being embedded right now.
    private(set) var indexing: Set<Bookmark.ID> = []
    private var queue: [Bookmark.ID] = []
    private var worker: Task<Void, Never>?

    /// What the vectors must have been made with to count as indexed. The Mac's `indexSignature`,
    /// spelled the same way, because it is compared against strings the Mac wrote.
    var indexSignature: String { "\(choice.modelID)@\(TextChunker.indexVersion)" }

    init(database: any DatabaseWriter, choice: EmbeddingModelChoice) {
        self.database = database
        self.choice = choice
        index = VectorIndex(dimension: choice.dimension)
        prepareVectorTable()
    }

    /// Hands over the thing that actually makes vectors, and starts on whatever was waiting.
    ///
    /// Separate from `init` because the two happen at different times on every front that is not
    /// the Mac: the database opens before there is a window, and the embedder needs a page.
    func use(_ embedder: any Embedder) {
        precondition(embedder.dimension == choice.dimension,
                     "the embedder makes \(embedder.dimension)-wide vectors and the index is \(choice.dimension) wide")
        self.embedder = embedder
        resumeIndexing()
    }

    /// The `vec0` table for this embedder's dimension, made if this is the first time six has seen
    /// that width. A failure here is the one worth logging loudly: everything downstream of it looks
    /// like an embedder that is not working.
    private func prepareVectorTable() {
        do {
            try database.write { db in try index.create(in: db) }
        } catch {
            Log.error(.bookmarks, "vector table failed: \(error)")
        }
    }

    // MARK: Saving

    /// Saves a page now and reads it a moment later.
    ///
    /// Two writes rather than one, and the order is the point. The row exists before the page is
    /// read, so a star points the right way the moment it is pressed; `ReadablePage` then runs in
    /// the page and the second save replaces the title-only passage with the whole text. A page that
    /// cannot be read — a canvas, a PDF, one that has not drawn anything yet — keeps the first save,
    /// which is still a bookmark and still findable by its title.
    ///
    /// The Mac reads first and saves after, and can afford to: its star waits on a `Task` with a
    /// spinner beside it. The embedding the first save queued is not wasted work either way — `embed`
    /// re-reads the passages in the transaction that writes the vectors, and a run that finds them
    /// replaced leaves the row unstamped for the second save's own run.
    @discardableResult
    func save(url: URL, title: String, profileID: UUID, reading page: some PageScriptRunner) throws -> Bookmark {
        let saved = try save(url: url, title: title, profileID: profileID)
        Task { await read(page, into: saved.id, url: url, title: title, profileID: profileID) }
        return saved
    }

    private func read(_ page: some PageScriptRunner, into id: Bookmark.ID, url: URL, title: String, profileID: UUID) async {
        let readable: ReadablePage
        do {
            readable = try await ReadablePage.extract(from: page)
        } catch {
            Log.info(.bookmarks, "kept \(url) as its title only: \(error.localizedDescription)")
            return
        }
        // The star may have been pressed again while the page was being read. A bookmark removed
        // meanwhile stays removed, and one removed and saved again has a reader of its own.
        guard bookmark(for: url, in: profileID)?.id == id else { return }
        // The page's own claim first, the way the Mac takes it; a guess only where there is none.
        let language = readable.language.isEmpty
            ? LanguageGuess.source(claimed: "", sample: String(readable.text.prefix(2000))) ?? ""
            : readable.language
        do {
            let saved = try save(url: url, title: readable.title.isEmpty ? title : readable.title,
                                 excerpt: readable.excerpt, siteName: readable.siteName, language: language,
                                 imageURL: readable.imageURL, text: readable.text, profileID: profileID)
            keepCopy(of: readable, as: saved)
            Log.debug(.bookmarks, "read \(readable.text.count) characters of \(url)")
        } catch {
            Log.error(.bookmarks, "could not save the text of \(url): \(error)")
        }
    }

    /// Writes the page's Markdown beside the row and records the file's name on it. Every read
    /// rewrites the copy under the same name, so starring a page again brings its copy up to date.
    /// A copy that cannot be written is logged and nothing more: the row and its passages are the
    /// bookmark, and the file is the human copy of it.
    private func keepCopy(of page: ReadablePage, as bookmark: Bookmark) {
        guard let folder = profileFolder?(bookmark.profileID) else { return }
        let fileName = bookmark.fileName.isEmpty ? BookmarkFile.name(for: bookmark.title, id: bookmark.id) : bookmark.fileName
        let profileName = (try? database.read { db in
            try ProfileIdentity.where { $0.id.eq(bookmark.profileID) }.fetchAll(db)
        })?.first?.name
        do {
            try BookmarkFile.write(markdown: page.markdown, byline: page.byline, bookmark: bookmark,
                                   profileName: profileName, to: Self.copy(fileName, in: folder))
            guard fileName != bookmark.fileName else { return }
            try database.write { db in
                try Bookmark.where { $0.id.eq(bookmark.id) }.update { $0.fileName = fileName }.execute(db)
            }
        } catch {
            Log.error(.bookmarks, "could not keep a copy of \(bookmark.url): \(error)")
        }
    }

    private static func copy(_ fileName: String, in profileFolder: URL) -> URL {
        profileFolder.appending(path: "Bookmarks", directoryHint: .isDirectory).appending(path: fileName)
    }

    /// Saves a page and queues its passages for embedding.
    ///
    /// `text` is the page's readable body, and `""` where there is none — the title and the
    /// excerpt are still a passage, still embedded, and still findable by meaning, which is the
    /// difference between a bookmark list and a search. `TextChunker` puts them in chunk 0 for
    /// exactly this reason.
    @discardableResult
    func save(
        url: URL, title: String, excerpt: String = "", siteName: String = "", language: String = "",
        imageURL: URL? = nil, text: String = "", profileID: UUID
    ) throws -> Bookmark {
        let existing = try database.read { db in
            try Bookmark.where { $0.profileID.eq(profileID) }.where { $0.url.eq(url) }.fetchAll(db)
        }.first
        let id = existing?.id ?? UUID()
        let hash = Checksum.sha256(Data(text.utf8))
        // Same text, already embedded by this model: there is nothing to redo, and re-embedding a
        // page because it was starred twice is the kind of work a browser should not be doing.
        let unchanged = existing.map {
            $0.contentHash == hash && $0.indexedAt != nil && $0.embeddingModel == indexSignature
        } ?? false
        let bookmark = Bookmark(
            id: id, profileID: profileID, url: url,
            title: title.isEmpty ? (existing?.title ?? "") : title,
            excerpt: excerpt, siteName: siteName.isEmpty ? (url.host() ?? "") : siteName,
            imageURL: imageURL ?? existing?.imageURL, fileName: existing?.fileName ?? "", language: language,
            characterCount: text.count, createdAt: existing?.createdAt ?? Date(),
            indexedAt: unchanged ? existing?.indexedAt : nil,
            embeddingModel: unchanged ? indexSignature : "",
            indexError: unchanged ? existing?.indexError : nil,
            refreshedAt: existing?.refreshedAt, contentHash: hash, refreshError: nil
        )
        if unchanged {
            try database.write { db in try Self.upsert(bookmark, in: db) }
            onChange?()
            return bookmark
        }
        let chunks = TextChunker.chunks(title: bookmark.title, excerpt: excerpt, text: text)
        try database.write { [index] db in
            try Self.upsert(bookmark, in: db)
            try Self.dropIndex(of: id, index: index, in: db)
            for (ord, text) in chunks.enumerated() {
                try BookmarkChunk.insert { BookmarkChunk(id: UUID(), bookmarkID: id, ord: ord, text: text) }.execute(db)
            }
        }
        onChange?()
        enqueue(id)
        return bookmark
    }

    /// Removes a bookmark, its passages and its vectors — a `vec0` table has no foreign key to do
    /// the last of those for us.
    func remove(_ id: Bookmark.ID) throws {
        queue.removeAll { $0 == id } // not yet embedded: never will be
        let row = try database.read { db in try Bookmark.where { $0.id.eq(id) }.fetchAll(db) }.first
        try database.write { [index] db in
            try Self.dropIndex(of: id, index: index, in: db)
            try Bookmark.where { $0.id.eq(id) }.delete().execute(db)
        }
        // The copy goes with the bookmark, as it does on the Mac.
        if let row, !row.fileName.isEmpty, let folder = profileFolder?(row.profileID) {
            try? FileManager.default.removeItem(at: Self.copy(row.fileName, in: folder))
        }
        onChange?()
    }

    /// Finishes what an earlier run left unindexed, and re-embeds after a change of model. Called
    /// at launch, once the embedder is wired.
    func resumeIndexing() {
        guard embedder != nil else { return }
        let pending = (try? database.read { db in
            try Bookmark.where { $0.indexError.is(nil) }.order { $0.createdAt.desc() }.fetchAll(db)
        }) ?? []
        for bookmark in pending where bookmark.indexedAt == nil || bookmark.embeddingModel != indexSignature {
            enqueue(bookmark.id)
        }
    }

    // MARK: Reading

    /// This profile's bookmarks, newest first, narrowed by a literal match on the title or the
    /// address.
    ///
    /// Beside `search` rather than instead of it, and the two answer different questions. A list
    /// with a field in it is filtered as you type and has to be exact and instant; a question put to
    /// the library is answered by meaning and costs an embedding. The Mac's bookmarks window has
    /// both for the same reason.
    func all(in profileID: UUID, matching query: String = "") -> [Bookmark] {
        let rows = (try? database.read { db in
            try Bookmark.where { $0.profileID.eq(profileID) }.order { $0.createdAt.desc() }.fetchAll(db)
        }) ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(trimmed) || $0.url.absoluteString.lowercased().contains(trimmed)
        }
    }

    /// The bookmark this address is saved as, if it is — what a star reads to know which way to
    /// point, and what a second star press removes.
    func bookmark(for url: URL, in profileID: UUID) -> Bookmark? {
        (try? database.read { db in
            try Bookmark.where { $0.profileID.eq(profileID) }.where { $0.url.eq(url) }.fetchAll(db)
        })?.first
    }

    // MARK: Searching

    /// The nearest passages to a question, as bookmarks, best first.
    ///
    /// The same two-step the Mac makes: sqlite-vec ranks chunks, and the chunks are folded into the
    /// documents they belong to, keeping each document's best passage as its snippet. `k * 4` rather
    /// than `k` because one long page can own the first four hits and would otherwise be the whole
    /// answer.
    func search(_ query: String, profileID: UUID?, limit: Int = 10) async throws -> [BookmarkHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let embedder else { return [] }
        guard let embedding = try await embedder.embed([trimmed], as: .query).first else { return [] }
        let rows = try await database.read { [index] db in
            try index.search(embedding.vector, model: embedding.model, profileID: profileID, k: limit * 4, in: db)
        }
        guard !rows.isEmpty else { return [] }
        let chunks = try await database.read { db in
            try BookmarkChunk.where { $0.id.in(rows.map(\.chunkID)) }.fetchAll(db)
        }
        let byID = Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var best: [Bookmark.ID: (chunk: BookmarkChunk, distance: Double)] = [:]
        for row in rows {
            guard let chunk = byID[row.chunkID], best[chunk.bookmarkID] == nil else { continue }
            best[chunk.bookmarkID] = (chunk, row.distance)
            if best.count == limit { break }
        }
        let found = Array(best.keys)
        let bookmarks = try await database.read { db in
            try Bookmark.where { $0.id.in(found) }.fetchAll(db)
        }
        return bookmarks.compactMap { bookmark in
            guard let match = best[bookmark.id] else { return nil }
            // Cosine similarity: 1 − distance. E5 keeps everything above ~0.7; the ranking is what counts.
            return BookmarkHit(
                bookmark: bookmark,
                score: max(0, min(1, 1 - match.distance)),
                snippet: String(match.chunk.text.prefix(300))
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: Indexing

    private func enqueue(_ id: Bookmark.ID) {
        // No embedder yet: the row is written and `indexedAt` is nil, which is the whole of what
        // "waiting to be indexed" means here. `use` comes back for it.
        guard embedder != nil, !queue.contains(id) else { return }
        queue.append(id)
        indexing.insert(id)
        if worker == nil { worker = Task { await drain() } }
    }

    /// Waits until the queue is empty. Only a self-test wants this — the app queues and forgets —
    /// but a test that cannot tell "not indexed yet" from "not indexed" is not a test.
    func waitForIndexing() async {
        while let worker {
            await worker.value
            // `drain` clears it on the way out; anything there now is a run that started while this
            // one was waiting, and waiting for that one too is the whole point.
            if self.worker == nil { break }
        }
    }

    private func drain() async {
        defer { worker = nil }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            await embed(id)
            indexing.remove(id)
            onChange?()
        }
    }

    /// Embeds one bookmark's passages and writes them into the vector table under its profile.
    private func embed(_ id: Bookmark.ID) async {
        let bookmark = (try? await database.read { db in try Bookmark.where { $0.id.eq(id) }.fetchAll(db) })?.first
        guard let bookmark else { return }
        let chunks = (try? await database.read { db in
            try BookmarkChunk.where { $0.bookmarkID.eq(id) }.order(by: \.ord).fetchAll(db)
        }) ?? []
        guard !chunks.isEmpty else { return }
        guard let embedder else { return }
        let signature = indexSignature
        let started = ContinuousClock.now
        do {
            let embeddings = try await embedder.embed(chunks.map(\.text), as: .passage)
            Log.debug(.bookmarks, "embedded \(chunks.count) passages of \(bookmark.displayTitle) in \(ContinuousClock.now - started)")
            let now = Date()
            try await database.write { [index] db in
                // Seconds have passed: the bookmark may be gone, or saved again with new passages.
                // Only what is still in the tables gets a vector, in the transaction that checks.
                let live = Set(try BookmarkChunk.where { $0.bookmarkID.eq(id) }.select(\.id).fetchAll(db))
                guard try Bookmark.where({ $0.id.eq(id) }).count().fetchOne(db) ?? 0 > 0, !live.isEmpty else { return }
                try index.remove(chunkIDs: chunks.map(\.id), in: db)
                for (chunk, embedding) in zip(chunks, embeddings) where live.contains(chunk.id) {
                    try index.insert(embedding.vector, chunkID: chunk.id, profileID: bookmark.profileID,
                                     model: embedding.model, in: db)
                }
                // Saved again meanwhile: the new passages are queued on their own, and stamping the
                // row now would say this run had indexed them.
                guard live == Set(chunks.map(\.id)) else { return }
                let note: String? = chunks.count >= TextChunker.maxChunks
                    ? "Indexed the first \(TextChunker.maxChunks) passages only" : nil
                try Bookmark.where { $0.id.eq(id) }.update { row in
                    row.indexedAt = #bind(now)
                    row.embeddingModel = signature
                    row.indexError = #bind(note)
                }.execute(db)
            }
        } catch {
            let message = error.localizedDescription
            try? await database.write { db in
                try Bookmark.where { $0.id.eq(id) }.update { $0.indexError = #bind(message) }.execute(db)
            }
            Log.error(.bookmarks, "index failed for \(bookmark.url): \(message)")
        }
    }

    // MARK: Rows

    /// The table's `ON CONFLICT REPLACE` sits on `NOT NULL`, not on the key, so a re-save is
    /// delete + insert. `BookmarkStore.upsert` says the same thing about the same table.
    private static func upsert(_ bookmark: Bookmark, in db: Database) throws {
        try Bookmark.where { $0.id.eq(bookmark.id) }.delete().execute(db)
        try Bookmark.insert { bookmark }.execute(db)
    }

    /// Everything the index holds for a bookmark: its passages and their vectors.
    private static func dropIndex(of id: Bookmark.ID, index: VectorIndex, in db: Database) throws {
        let chunkIDs = try BookmarkChunk.where { $0.bookmarkID.eq(id) }.select(\.id).fetchAll(db)
        try index.remove(chunkIDs: chunkIDs, in: db)
        try BookmarkChunk.where { $0.bookmarkID.eq(id) }.delete().execute(db)
    }
}
