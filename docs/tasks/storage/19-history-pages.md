# 19. Search over what was read, not only what was saved

The first item is the task. The rest is the state of the store, kept here because whoever does the first needs it.

SQLite is the system of record — chosen and built: SQLiteData over GRDB for `visits`, `settings`, bookmarks and
their chunks and vectors (`Savoia/Data/`, `Savoia/Bookmarks/`, [architecture.md](../../architecture.md#persistence),
[bookmarks.md](../../bookmarks.md)). The app-state snapshot stays JSON — one small document, not a table. What is left:

- **History pages through the same store.** Bookmarks are the first RAG slice; history is the second: `pages(url,
  fetchedAt, text)` + FTS5 for visited pages, chunks and vectors like bookmarks, retrieval over what was *read*, not
  only what was saved. Decide when a visit is worth its text (dwell time, scroll, explicit "remember this").
- **`Retrieval` as a protocol.** The sqlite-vec KNN lives inside `BookmarkStore.vectorSearch` — one function to
  swap. Lift it behind a seam before a second index appears ([storage.md](../../storage.md)).
- **A bigger embedder when small isn't enough.** ~~One line in `MLXEmbedder.configuration`~~ — done, as a setting:
  `EmbeddingModelChoice` offers `multilingual-e5-small` and `multilingual-e5-base`, recommended by the Mac's memory
  and overridable ([bookmarks.md](../../bookmarks.md)). What is still open is a third rung — `multilingual-e5-large` or
  `bge-m3`, at 2 GB and up — and whether the ladder should be one the user climbs at all rather than one Savoia climbs
  for them. An ANN index (USearch) only past ~100k chunks — `vec0` is brute force too, just in C.
- **Prototypes worth an afternoon**, both caches over SQLite, never systems of record:
  [Wax](https://github.com/christopherkarani/Wax) — one `.wax` file with FTS5 + Metal HNSW, hybrid search in one
  query, own embedder and an MCP server; Apple Silicon first, single writer, v0.2. VecturaKit — embed + index +
  BM25 hybrid in one Swift API over MLX; Apple-only, own files.
- **The vector index off the Mac** (the `dev` branch, where the other fronts live). ~~Out of scope for the Linux phase~~ — built for both: sqlite-vec is registered
  per process (`Vectors.register()`) before the first connection, `VectorIndex` holds the `vec0` table and the KNN for
  every front, and `BookmarkIndexer` writes the rows, the passages and the vectors. The embedder is the same E5, run
  by transformers.js in a `PageSandbox` (`WebEmbedder`). Measured on Windows; **Linux is written and unrun** — the
  container is on the Mac. Windows has the bookmark button and `⌃D` now, beside the address the way the Mac's is. A saved page
  is its whole text there too: `ReadablePage` is in `SavoiaCore` and runs through `PageScriptRunner`, so the star saves
  the row at once and replaces its title-only passage with the page's a moment later. The Markdown copy is written
  beside the row there as well (`BookmarkFile`). What is still owed is somewhere to *see* the library — Windows has no
  bookmarks window, and Linux's `BookmarksSheet` searches titles and addresses only — and the hourly refresh, which
  needs an off-screen page with the profile's cookies.
- **Linux build of the data layer** (the `dev` branch). ~~Verify early~~ — done, and it builds: GRDB, SQLiteData, sqlite-vec
  and the `@Table` macros all compile on Swift 6.3.3/aarch64, as do `AppDatabase`, `ConfigurationStore`, `History`
  and `Bookmark`. No fallback needed. What it costs is two pins: `swift-sharing` 2.10.0 and
  `combine-schedulers` 1.2.1 regressed on Linux, and `sqlite-data` 1.11.0 does not compile against
  `structured-queries` 0.38 on any platform. The package's `Package.resolved` is seeded from the app's,
  which answers all three — so `swift package update` is Linux-breaking. Measured in [storage.md](../../storage.md).
- `record_name` / `sync_state` columns for [sync](../../sync.md) when it comes; the schema already follows SQLiteData's
  CloudKit rules (UUID text keys with `ON CONFLICT REPLACE`, no other `UNIQUE`, no column drops, BLOBs in their own
  tables), so nothing migrates.

Rejected, so it isn't re-litigated: Core Data / SwiftData (Apple-only, no FTS or vectors), Realm (sync dropped, no
Linux Swift), LMDB/RocksDB (everything built on top), Couchbase Lite (its own sync), DuckDB (poor for many small
writes), libSQL / Turso (native vectors, but not the system `sqlite3`, young Swift SDK), ObjectBox (closed core, no
Linux), PGlite (WASM runtime, data unreachable from `Savoia --mcp`), Qdrant / Milvus / Weaviate / Chroma (server
clients, nothing embedded).

## Done when

A page visited and not bookmarked is found from the start page's personal search by its text, with a rule for
which visits are worth their text that Artem has agreed to, and what it costs on disk per thousand pages written
into [storage.md](../../storage.md).
