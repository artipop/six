# TODO

What is planned but not built. Ordered by how much it is missed, not by effort.

## Document windows and Save As

A column that holds text instead of a page, and the browser's oldest command — **Save As…** — for both kinds. Notes
and documents are useful on their own; they are also the half that [deep research](deep-research.md) is missing, which
is where the design lives.

- `TabContent` on `BrowserTab`: `.web(WebPage)` or `.document(TextDocument)`; the layout does not care which.
- Markdown source in a `TextEditor`, rendered preview through a `WebPage` — export to HTML and PDF then comes free.
- Documents in `~/Library/Application Support/six/Documents/<id>.md`, the snapshot keeping id, title and column.
- `⌘S` / **Save As…** over `NSSavePanel` (the app is not sandboxed): documents as `.md` / `.html` / `.pdf`, pages as
  `.webarchive` / `.html` / `.pdf` / `.txt`. Remember the last folder and the document's own file URL.
- Neighbour worth doing at the same time: **downloads** (`WKDownload`), which six does not handle at all yet.

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

## Highlights and passage links

Useful on its own — a highlighter that remembers — and the part of [deep research](deep-research.md#4-highlighted-passages)
that turns a list of links into evidence: the model picks the paragraphs that answer the question (by number, from an
extraction six makes, so it never retypes the text), and six anchors them with Web Annotation selectors, paints them
through the CSS Custom Highlight API and writes them into the document as `#:~:text=` links that work in any browser.
Dynamically loaded pages get a re-anchor budget, not a promise; canvas text and PDFs are out of reach and should say
so. Highlights live per URL in `highlights.json`, so they come back next week whether or not a run does.

## Passkeys and passwords

Sign in with a passkey (or a saved password) on any site, through the system UI. WebAuthn inside a third-party
`WKWebView` is gated by Apple's browser entitlements, so this is as much a paperwork task as a coding one. The plan,
the fallbacks and what to verify first are in [passkeys.md](passkeys.md). **Next up.**

## Sync through CloudKit — history first

History on every Mac (and later everything else that is a plain record: profiles, highlights, documents). Private
database, `CKSyncEngine`, one record per visit — visits are immutable, so there is nothing to merge. Design, limits
and what CloudKit can and cannot carry (vectors included) in [sync.md](sync.md). Depends on the storage move below
for anything bigger than history.

## Storage: SQLite under history, with RAG in mind

**Bookmarks are the first RAG slice** ([bookmarks.md](bookmarks.md)): page → Markdown file + chunks + on-device
vectors, hybrid search, tools for the assistant and MCP. What it settled: no embedding API in Foundation Models
(`NLContextualEmbedding` instead, per-script spaces), and no `sqlite-vec` on the system SQLite (extension loading is
compiled out; brute-force cosine over BLOBs, an own SQLite build if that ever isn't enough). History pages would go
through the same store.

**Done for history and settings** (`six/Data/`, [architecture.md](architecture.md#persistence)) — SQLiteData over
GRDB, schema laid down by its CloudKit rules. What remains is the step that matters:
page text and embeddings for retrieval over what was read. One local store for visits, page content, chunks and
vectors — SQLite through the system `SQLite3` module (macOS and Linux, no dependency to fight the SDK override with),
FTS5 for titles and text, vectors as blobs with a brute-force cosine pass (fine to ~100k chunks) or `sqlite-vec` if it
ever isn't. `HistoryStore`'s interface stays; only the backend changes. The overall shape — portable core, Apple/Linux adapters
behind protocol seams — is drawn in [storage.md](storage.md). The app-state snapshot stays JSON — that is
one small document, not a table.

Why SQLite and not something else — the alternatives that were actually weighed:

| | what it is | verdict |
|---|---|---|
| Core Data / SwiftData | Apple's ORM over SQLite, free CloudKit sync via `NSPersistentCloudKitContainer` | Apple-only; no FTS, no vectors; the sync we need is custom anyway. No |
| Realm | embeddable object database | MongoDB dropped Device Sync and is moving Realm to the community (2024); no Linux for Swift. No |
| LMDB / RocksDB / LevelDB | key-value stores | fast, but SQL, FTS and vectors would all be built on top. No |
| Couchbase Lite | document DB with its own replication | sync is theirs, not CloudKit; heavy SDK, paid on Linux. No |
| DuckDB | analytical columnar engine, has vector functions and a Swift package | great for analytics, poor for many small writes (visits); no row bookkeeping for CloudKit; big binary. No |
| LanceDB / Chroma / Qdrant | vector databases | server-side or no Swift client; overkill for ~100k on-device chunks. No |
| USearch / Faiss | vector *indexes* | USearch (C++, Swift bindings, macOS/iOS/Linux) is the candidate for the index once brute-force / `sqlite-vec` isn't enough. Storage is still SQLite |
| Turso / libSQL | SQLite fork with native vectors (`F32_BLOB`, `vector_distance_cos`, DiskANN index) and a Swift SDK over a Rust core | the tempting "one database for everything": SQLite + FTS5 + vectors, no extension. Young Swift SDK, not the system `sqlite3` (GRDB doesn't sit on it without a custom build), Linux through the Rust library. **Try the build** alongside GRDB |
| ObjectBox | object database with HNSW vector search on device, native Swift SDK | a replacement for SQLite, not an addition; closed core, no Linux for Swift. No |
| [Wax](https://github.com/christopherkarani/Wax) | local-first shared memory for AI agents: one `.wax` file (WAL, LZ4 frames) embedding SQLite FTS5 for text and a Metal HNSW for vectors, hybrid BM25 + vector search in one query, EAV facts, its own embedder (MiniLM / Foundation Models) and an MCP server; Swift 6, Apache 2.0, ~6 ms p95 | **first candidate for the retrieval and agent-memory layer**: a page read goes in, an agent asks over MCP what was read about X. Not a system of record — single file, single writer, Apple Silicon first, Linux text-only, v0.2 — so it is a *rebuildable cache over SQLite*, and it syncs as records that each device feeds into its own `.wax` (iOS 18+ works), never as the file itself. Prototype next to the SQLite move |
| VecturaKit | small Swift-native on-device vector store: embeds and searches in one API (MLX / Foundation Models embeddings), hybrid with BM25, persisted to disk | interesting for the *retrieval* layer — it does embed + index + hybrid search together, which is exactly the RAG step. Apple-only (MLX), young, and its store is its own files, so it would sit next to SQLite as a cache, not replace it. Worth a prototype for the search side |
| PGlite | Postgres compiled to WASM, pgvector included | needs a WASM runtime or a hidden web view and a JS bridge; data in IndexedDB, unreachable from `six --mcp`, nothing on iOS in the background. No |
| Qdrant / Milvus / Weaviate / Chroma | server-side vector databases | the Swift libraries are clients to a running server (Qdrant's is gRPC); no embedded mode, nothing on a phone. Only if the index ever moves off the device |
| JSON / JSONL files | the current state | whole-file rewrites, everything in memory. Stopgap |

Access layer, as built: **[SQLiteData](https://github.com/pointfreeco/sqlite-data)** (Point-Free, MIT) — `@Table`
structs, typed queries and `#sql` from StructuredQueries, GRDB underneath, and a ready `SyncEngine` over
`CKSyncEngine` with per-column last-write-wins, opt-in tables and sharing. Its schema rules are ours now: UUID text
primary keys with `ON CONFLICT REPLACE`, no `UNIQUE` on other columns, no column removal or renaming, BLOBs in their
own tables (every BLOB column becomes a `CKAsset` — so embeddings go either into a local-only table or as text).
Not declared for Linux in its `Package.swift`; the core is `#if canImport(CloudKit)`-free and GRDB/StructuredQueries
do build there, so verify early and fall back to plain GRDB if it doesn't. Underneath: **GRDB** (a Swift layer over SQLite: typed queries, Codable rows, migrations, `DatabasePool` with WAL,
`ValueObservation`, FTS5; macOS/iOS/Linux). It is a SwiftPM dependency, and the `SDKROOT` override
([build.md](build.md)) is *not* the obstacle it was for ClaudeForFoundationModels: that library touches the
FoundationModels executor ABI, GRDB touches only Foundation and the system `sqlite3`, both stable across two
revisions of the same SDK. Add the package, build, and only vendor if something actually breaks. A hand-written
wrapper (~200 lines) is the fallback, not the plan.

Schema to lay down once, so nothing migrates later: `profiles`, `visits(profile_id, url, title, visited_at)`,
`pages(url, fetched_at, text)` + `pages_fts`, `chunks(page_id, ord, text, embedding BLOB, embedding_model)`, and
`record_name` + `sync_state` on every table for [sync](sync.md).

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Downloads UI once `WKDownload` exists: where a file went, and a way to open it.
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
