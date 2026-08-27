# TODO

What is planned but not built. Ordered by how much it is missed, not by effort.

## Save As: web archives and downloads

Document windows, Save As and highlights are built ([deep-research.md](deep-research.md)). What Save As still
lacks: `.webarchive` for pages — `WebPage` has no `createWebArchiveData` today, so a page saves as `.html` (its
source), `.pdf` or `.txt` — and **downloads** (`WKDownload`), which six does not handle at all yet.

## Bookmarks: images

Today a bookmark keeps images only as `![alt](src)` in the Markdown and `og:image` in the front matter; nothing in
a picture is searchable. The plan, in the order it should be built ([bookmarks.md](bookmarks.md#embeddings) has what
the SDK offers and doesn't):

1. **OCR + labels, locally (Vision)** — the base. When a page is bookmarked, download its large images (≥ 120 px, at
   most ~20 per page) into `Bookmarks/<slug>/images/`, run `RecognizeTextRequest` (multilingual OCR) and
   `ClassifyImageRequest` (~1300 labels) on each, and store the result as chunks of a new kind —
   `bookmark_chunks(kind: image, imageURL, text)` — embedded like any text. Screenshots, diagrams, infographics,
   menus, tables-as-pictures become findable by their words; a photo by its labels. Don't lean on `alt` or
   `<figcaption>` — they are usually empty or wrong; use them only as extra words when present.
2. **Descriptions from Foundation Models** (macOS 27: the on-device model takes `Attachment<ImageAttachmentContent>`
   — `CGImage`, `CIImage`, `CVPixelBuffer`, `imageURL:`; nothing else, no PDF). Ask for a one-line description per
   image, in the user's language, and store it as another image chunk. Seconds per image, needs Apple Intelligence
   assets — a budget of ~10 images per page, in the background after step 1. Decide after seeing step 1 on real pages.
3. **A multimodal embedder** (Voyage `voyage-multimodal-3`, Cohere Embed v4) as a second `Embedder` conformer:
   image chunks embedded as images, text as text, one space — real text→image search and cross-lingual text at the
   same time. Remote, keyed, images leave the Mac; a setting, off by default.

PDFs: the model doesn't take them; `PDFPage.string` for the text layer and page renders as images through step 1/2
when `ReadablePage` learns to read a PDF `WebPage`.

## Picture-in-picture

Two different features that both deserve the name:

- **Video PiP** — WebKit's own, for `<video>`: allow it in `WebPage.Configuration` and make sure the floating player
  survives its window being scrolled off screen or turned into a placeholder card (a column far from the viewport
  loses its live `WebView` today — the PiP player must not die with it).
- **Window PiP** — any window as a small always-on-top panel: an `NSPanel` at `.floating` level hosting the page,
  which leaves the strip while it floats and returns to its column when closed. This is niri's floating layer, and the
  same mechanism would later serve a proper floating-window mode.

## Passkeys and passwords

Sign in with a passkey (or a saved password) on any site, through the system UI. WebAuthn inside a third-party
`WKWebView` is gated by Apple's browser entitlements, so this is as much a paperwork task as a coding one. The plan,
the fallbacks and what to verify first are in [passkeys.md](passkeys.md). **Next up.**

## Sync through CloudKit — history first

History on every Mac (and later everything else that is a plain record: profiles, highlights, documents). Private
database, `CKSyncEngine`, one record per visit — visits are immutable, so there is nothing to merge. Design, limits
and what CloudKit can and cannot carry (vectors included) in [sync.md](sync.md). The store is ready for it — see the sync
columns under Storage below.

## Storage: history pages and retrieval

SQLite is the system of record — chosen and built: SQLiteData over GRDB for `visits`, `settings`, bookmarks and
their chunks and vectors (`six/Data/`, `six/Bookmarks/`, [architecture.md](architecture.md#persistence),
[bookmarks.md](bookmarks.md)). The app-state snapshot stays JSON — one small document, not a table. What is left:

- **History pages through the same store.** Bookmarks are the first RAG slice; history is the second: `pages(url,
  fetchedAt, text)` + FTS5 for visited pages, chunks and vectors like bookmarks, retrieval over what was *read*, not
  only what was saved. Decide when a visit is worth its text (dwell time, scroll, explicit "remember this").
- **`Retrieval` as a protocol.** The sqlite-vec KNN lives inside `BookmarkStore.vectorSearch` — one function to
  swap. Lift it behind a seam before a second index appears ([storage.md](storage.md)).
- **A bigger embedder when small isn't enough.** `multilingual-e5-small` ranks well within a language and passably
  across; `multilingual-e5-base` / `bge-m3` are one line in `MLXEmbedder.configuration` (and a bigger download) if
  cross-lingual questions keep missing. An ANN index (USearch) only past ~100k chunks — `vec0` is brute force too,
  just in C.
- **Prototypes worth an afternoon**, both caches over SQLite, never systems of record:
  [Wax](https://github.com/christopherkarani/Wax) — one `.wax` file with FTS5 + Metal HNSW, hybrid search in one
  query, own embedder and an MCP server; Apple Silicon first, single writer, v0.2. VecturaKit — embed + index +
  BM25 hybrid in one Swift API over MLX; Apple-only, own files.
- **Linux build of the data layer.** SQLiteData isn't declared for Linux in its `Package.swift`; its core is
  `#if canImport(CloudKit)`-free and GRDB/StructuredQueries build there. Verify early, fall back to plain GRDB.
- `record_name` / `sync_state` columns for [sync](sync.md) when it comes; the schema already follows SQLiteData's
  CloudKit rules (UUID text keys with `ON CONFLICT REPLACE`, no other `UNIQUE`, no column drops, BLOBs in their own
  tables), so nothing migrates.

Rejected, so it isn't re-litigated: Core Data / SwiftData (Apple-only, no FTS or vectors), Realm (sync dropped, no
Linux Swift), LMDB/RocksDB (everything built on top), Couchbase Lite (its own sync), DuckDB (poor for many small
writes), libSQL / Turso (native vectors, but not the system `sqlite3`, young Swift SDK), ObjectBox (closed core, no
Linux), PGlite (WASM runtime, data unreachable from `six --mcp`), Qdrant / Milvus / Weaviate / Chroma (server
clients, nothing embedded).

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- Deep research without an agent: a native loop over the ⌘K model for machines with no Claude Code / Codex, and
  exporting a run as one HTML file with its sources inlined ([deep-research.md](deep-research.md)).
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Downloads UI once `WKDownload` exists: where a file went, and a way to open it.
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
