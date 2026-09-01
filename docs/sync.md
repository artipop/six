# Sync through CloudKit — plan

*Not built yet. Tracked in [todo.md](todo.md). History first; the rest of the app state later.*

## What syncs, in what order

1. **History** — one record per visit: `profileID`, `url`, `title`, `visitedAt`. Visits never change, so there is
   nothing to merge; deletions ("forget", "clear profile") are tombstones or per-record deletes. This is the ideal
   first payload: immutable, small, and losing a few is harmless.
2. **Profiles** — name, colour, and a stable id so two Macs agree on which history belongs where. The
   `WKWebsiteDataStore` (cookies, logins) does **not** sync — CloudKit is not the place for session cookies, and
   passkeys already come through iCloud Keychain.

   The schema is already cut for it. `SyncEngine(for:tables:privateTables:)` names what travels and there is no
   filter below the table, so the profile is two tables: **`profiles(id, name, colorHex, ord)`** — the half that may
   be named — and **`profile_storage(id, dataStoreID, workingDirectoryPath)`**, which never may be, because both of
   its columns are paths on *this* machine. `ProfileStore` joins them, so nothing above it knows. A profile arriving
   from another Mac has no `profile_storage` row and is given a fresh data store on arrival, which is the right
   answer: it is a profile you have not signed into here.
3. **Highlights, documents, named workspaces** — once they exist ([todo.md](todo.md)). Not the live strip: which
   windows are open on *this* Mac is per-device state, like Safari's "iCloud Tabs" which is a list, not the layout.
4. **Chats** — the ACP session id is only valid on the machine whose agent created it, so a chat can sync as a
   transcript but the session can't be resumed elsewhere. Later, if at all.

## How

- **Private database**, one custom zone (`six`), record types per table. Zones give atomic batches and change
  tokens; the default zone doesn't.
- **`CKSyncEngine`** (macOS 14+): it owns the push/pull loop, batching, retries, account changes and change tokens;
  we implement `nextRecordZoneChangeBatch` (what to send) and `handleEvent` (what came in). Far less code than raw
  `CKModifyRecordsOperation`, and it is what Apple uses in its own apps now.
- **Local store is the source of truth**, sync is a mirror: every local row keeps `recordName` and a `pending`
  flag; the engine reads the pending rows, and writes fetched records back into the store. SQLite is in place and
  its schema already follows SQLiteData's CloudKit rules, so this is a matter of adding the columns and opting
  tables into its `SyncEngine`.
- **Portability**: everything CloudKit lives behind a `SyncEngine` protocol in `six/Sync/`; CloudKit is
  Apple-only (there is a JS/REST *CloudKit Web Services* API, but it needs a web sign-in and is not a client SDK for
  Linux). A Linux build gets a no-op engine, or a different backend behind the same protocol.
- **Requirements**: Developer Program, iCloud container `iCloud.org.deffun.six`, the `iCloud`/CloudKit entitlement
  and a provisioning profile — the same signing setup [passkeys.md](passkeys.md) needs, so do them together. App
  Sandbox is not required for CloudKit on macOS.
- **Privacy**: history is sensitive. Mark fields `encryptedValues` (end-to-end, keys in the user's Keychain), and
  do not sync profiles the user marks local-only.

## What CloudKit can carry

A `CKRecord` is a bag of fields: `String`, `Int/Double`, `Date`, `Bool`, `Data`, `CLLocation`, `CKReference`,
arrays of those, and `CKAsset` (a file). Limits that matter:

- **1 MB per record** for the fields together; `Data` blobs count.
- **Assets** are files stored alongside the record, in practice up to hundreds of MB; they are synced whole — no
  partial or incremental upload — and fetched on demand.
- **400 records / ~2 MB per modify operation** (the engine batches for you), rate limits per container.
- **Quota**: the private database counts against the user's iCloud storage, not ours. The public database counts
  against the app's free tier — irrelevant here.
- No server-side computation: queries are field predicates (`==`, `<`, `IN`, `BEGINSWITH`, …), no full-text search,
  no joins, no vector search.

## Vectors

Yes, embeddings can live in CloudKit — as data, not as an index:

- **One record per chunk**, embedding as a `Data` field: a 1536×float32 vector is 6 KB, a 768×float16 one is 1.5 KB;
  thousands fit comfortably under the record limit and sync incrementally with `CKSyncEngine`. Each device rebuilds
  its local index (SQLite blob column + brute-force cosine, or `sqlite-vec`) from the synced chunks. This is the
  right shape: chunks are immutable like visits, deletes are per-record, and two Macs adding chunks concurrently
  never conflict.
- **Shipping the whole `.db` as a `CKAsset`** also works and is the least code, but it is a whole-file sync: the
  last writer wins, every change re-uploads the entire file, and two Macs editing on the same day clobber each
  other. Acceptable only as a backup, not as sync.
- **Or don't sync vectors at all**: sync the *text* (chunks) and embed locally on each device. Cheaper on iCloud
  and the embeddings always match the local model — but only if every device runs the same embedding model and
  version; otherwise the same text yields different vectors and cross-device results diverge. Store
  `embeddingModel` on the chunk either way so a device can tell which vectors it can trust and re-embed the rest.
- CloudKit **cannot search** vectors. Retrieval is always local; CloudKit is the transport.

Recommendation for six: SQLite locally (visits, pages, chunks, vectors), CloudKit sync of visits first and chunks
+ embeddings second, whole-`.db` asset never except as an explicit "back up to iCloud" button.

## Phone writes, Mac embeds, phone searches

The shape that makes RAG work on an iPhone without asking it to run an embedding model: the phone is a thin client
for vectors, a Mac is the indexing node, CloudKit is the queue.

1. iPhone saves a note (`.md`) → a `documents` row with `sync_state = pending` → `CKSyncEngine` pushes it to the
   private zone.
2. The Mac app — the same binary, running in the menu bar or just open — has a `CKSubscription` on the zone, so
   CloudKit sends a silent push (`aps-environment` entitlement) and the engine fetches within seconds; no polling.
3. The Mac chunks and embeds locally (Foundation Models or whatever model is current), writes `chunks` with
   `embedding` and `embedding_model`, marks them pending, the engine pushes them.
4. The iPhone receives chunks with vectors, writes them to its SQLite and extends its index incrementally. It
   never embeds.

Details that keep this honest:

- **One indexer.** Two Macs would embed the same note twice. Either a chunk carries `embedded_by` and a claim
  timestamp (a duplicate is harmless — same content — only wasted work), or, simpler, one device is marked
  *indexer* in settings and the others only read.
- **Mac asleep or off** — the job waits. Meanwhile the phone searches by FTS (it has the text) and over whatever
  vectors have already arrived. Degraded, not broken.
- **Phone in the background** — CloudKit pushes reach iOS as background fetches with a limited budget; build the
  index in a `BGProcessingTask`, or on next open. Never at first launch in one go: scan vectors from SQLite in
  batches, not all in memory.
- **Index on the phone** — brute-force cosine over blobs is fine to ~100k chunks × 768 float16 (~150 MB,
  tens of ms on A17/M-series, `vDSP` if needed); `sqlite-vec` (one C file, builds into the iOS target) or USearch
  when it isn't.
- **Same schema, same container** — one `iCloud.org.deffun.six`, one schema, two targets. Notes, chunks and
  vectors are ordinary records well under 1 MB; no assets involved.
- **If the index is [Wax](https://github.com/christopherkarani/Wax)** ([todo.md](todo.md)) nothing above changes:
  the `.wax` file is a per-device cache rebuilt from the synced records, on the Mac and on the phone alike. Do not
  sync the file — it is the whole-file `CKAsset` case.
