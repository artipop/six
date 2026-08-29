# Storage and the portability seams — plan

*Where data lives, what is portable, and what is an Apple-only adapter behind a protocol. SQLite (SQLiteData over
GRDB) is built; the diagram is the shape the remaining seams must fit
([todo.md](todo.md#storage-history-pages-and-retrieval)). Related: [sync.md](sync.md), [passkeys.md](passkeys.md).*

```mermaid
flowchart TB
    subgraph UI["UI / views — SwiftUI on Apple, another front on Linux"]
        Views["ContentView · HistoryView · StartPage · AgentPanel"]
    end

    subgraph Core["Portable core — Foundation + Observation, no Apple API"]
        BS["BrowserState / NiriLayout"]
        HS["HistoryStore"]
        AS["AgentSessionStore / ACP / MCP"]
        Snap["AppStateSnapshot · JSON
tabs · strips · profiles · chats"]
        DB[("SQLite — system of record, via SQLiteData over GRDB
visits · settings · bookmarks
bookmark_chunks · bookmark_vectors")]
        RET{{"Retrieval protocol
index chunks · search query"}}
        EMB{{"Embedder protocol
embed text → vector + model id"}}
        SYNC{{"SyncEngine protocol
push pending · pull records"}}
        WEB{{"WebEngine protocol
load · url · title · navigations · siteData"}}
    end

    subgraph Apple["Apple-only adapters"]
        WK["WebKit WebPage / WKWebsiteDataStore"]
        FM["MLX · multilingual-e5-small
(Foundation Models has no embedder)"]
        WAX["Wax · .wax cache
FTS5 + Metal HNSW + own embedder"]
        CK["CloudKit · CKSyncEngine
private zone · push"]
        PK["Passkeys via browser entitlement"]
    end

    subgraph Linux["Linux adapters — interchangeable"]
        WKGTK["WebKitGTK / CEF"]
        LEMB["llama.cpp / ONNX embedder
same model and version"]
        VEC["sqlite-vec vec0 (built) → USearch
index inside the same SQLite"]
        NOSYNC["No-op sync · or own server /
CloudKit Web Services"]
    end

    Views --> BS
    Views --> HS
    Views --> AS
    BS --> Snap
    BS --> WEB
    HS --> DB
    AS --> DB
    HS --> RET
    RET --> DB
    RET --> EMB
    DB --> SYNC

    WEB -.-> WK
    WEB -.-> WKGTK
    EMB -.-> FM
    EMB -.-> LEMB
    RET -.-> WAX
    RET -.-> VEC
    SYNC -.-> CK
    SYNC -.-> NOSYNC
    WK -.-> PK

    classDef port fill:#e8f4ff,stroke:#4a90d9
    classDef apple fill:#fff2e0,stroke:#e8743b
    classDef linux fill:#e9f7ea,stroke:#3a9a4a
    class Snap,DB,RET,EMB,SYNC,WEB,BS,HS,AS port
    class WK,FM,WAX,CK,PK apple
    class WKGTK,LEMB,VEC,NOSYNC linux
```

## Reading it

- **Solid arrows** are the portable core: the JSON snapshot, SQLite through GRDB, and four protocol seams. Only
  the Linux build of SQLiteData itself was the open question, and it now has an answer — below.
- **Dotted arrows** are implementations of the seams — Apple on the left, the Linux replacement on the right. The
  core doesn't know which one is plugged in.
- **SQLite is the only system of record.** The `vec0` tables (sqlite-vec) are rebuildable indexes over it, as Wax or
  USearch would be; losing one is harmless, and a `.wax` file would never be synced.
- **`Embedder` returns a model id.** That is what keeps vectors compatible across devices and platforms: a chunk
  embedded by another model is re-embedded, not silently searched.
- **What exists**: `DB`, `HistoryStore`, `SettingsStore` (`six/Data/`, `six/Browser/History.swift`), and for
  bookmarks the `Embedder` protocol with `MLXEmbedder` (and `ContextualEmbedder`) behind it and `BookmarkStore` as
  the retrieval layer over sqlite-vec (`six/Bookmarks/`, [bookmarks.md](bookmarks.md)). `Retrieval` is not a protocol
  yet — the KNN lives inside `BookmarkStore.vectorSearch`, one function to swap. `SyncEngine` is not there.

## The seams, and what is still open

| seam | Apple | Linux | note |
|---|---|---|---|
| Web | `WebPage` (exists) | WebKitGTK / CEF | the most expensive seam; a Linux front is a different UI anyway, so in practice this is "keep the model out of the views", which is already the case |
| Embedder | multilingual-e5-small over MLX (built); `NLContextualEmbedding` as the no-download alternative | the same model over llama.cpp / ONNX | model ids + re-embedding is what is built: every vector carries its model, a query only meets its own |
| Retrieval | sqlite-vec `vec0` (built) | the same; `sqlite3_auto_extension` works there | on macOS the extension is entered per connection (`sqlite3_vec_init`), since the system SQLite has extension loading compiled out — [bookmarks.md](bookmarks.md#the-index) |
| Sync | SQLiteData's `SyncEngine` over CloudKit | no-op / own server | without an Apple account a Linux build cannot reach iCloud at all; accept that |

## SQLiteData on Linux: measured

Swift 6.3.3, aarch64, Ubuntu 24.04, in a container. **GRDB, StructuredQueries, the `@Table` and `#sql`
macros and sqlite-vec all compile there** — the build reaches 687 of 779 steps before it stops, and it
stops outside all of them.

What stops it is `SQLiteData` depending on `Sharing`, unconditionally
(`sqlite-data/Package.swift`, target dependency, not trait-gated), which reaches `combine-schedulers`,
whose `Internal/Lock.swift` uses `pthread_mutex_t` under a bare `import Foundation`. Swift 6.3 rejects
that: `initializer 'init()' is not available due to missing import of defining module 'CoreFoundation'`
`[#MemberImportVisibility]`. Upstream `main` still has no `import CoreFoundation`, so a version bump does
not help; and because the package sets its own language mode, neither `-Wwarning MemberImportVisibility`
nor `-swift-version 5` on the command line reaches it.

The way out is the one this file already implied. **six uses none of the layer that pulls `Sharing`** —
no `@FetchAll`, no `@Fetch`, no `@Shared` anywhere in `six/`; only `@Table`, `#sql` and
`defaultDatabase`. So on Linux the dependency is `swift-structured-queries` directly, which ships
`StructuredQueriesSQLite` and depends on neither `Sharing` nor `combine-schedulers`. The macros are the
same ones, so **every model file travels unchanged** and only `AppDatabase`'s plumbing — `defaultDatabase`
over a GRDB `DatabaseWriter` — needs a Linux arm.

That is a smaller fallback than "plain GRDB" ([todo.md](todo.md#storage-history-pages-and-retrieval)
assumed the query layer might have to go too; it does not).
