# Sync through CloudKit — plan

*Not built yet. Tracked in [todo.md](todo.md). History first; the rest of the app state later.*

## What syncs, in what order

1. **History** — one record per visit: `profileID`, `url`, `title`, `visitedAt`. Visits never change, so there is
   nothing to merge; deletions ("forget", "clear profile") are tombstones or per-record deletes. This is the ideal
   first payload: immutable, small, and losing a few is harmless.
2. **Profiles** — name, colour, and a stable id so two Macs agree on which history belongs where. The
   `WKWebsiteDataStore` (cookies, logins) does **not** sync — CloudKit is not the place for session cookies, and
   passkeys already come through iCloud Keychain.
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
  flag; the engine reads the pending rows, and writes fetched records back into the store. This is why the SQLite
  move ([todo.md](todo.md#storage-sqlite-under-history-with-rag-in-mind)) comes first for anything beyond history —
  a JSON file has no per-row bookkeeping.
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
