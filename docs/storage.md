# Storage and the portability seams — plan

*Where data lives, what is portable, and what is an Apple-only adapter behind a protocol. The next step is the
SQLite move ([todo.md](todo.md#storage-sqlite-under-history-with-rag-in-mind)); the rest of the diagram is the
shape that step must not break. Related: [sync.md](sync.md), [passkeys.md](passkeys.md).*

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
        FM["NLContextualEmbedding embedder
(Foundation Models has none)"]
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
        VEC["BLOB scan (today) → sqlite-vec / USearch
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

- **Solid arrows** are the portable core. Everything there builds on Linux as it is: the JSON snapshot (already),
  SQLite through GRDB (next), and four protocol seams.
- **Dotted arrows** are implementations of the seams — Apple on the left, the Linux replacement on the right. The
  core doesn't know which one is plugged in.
- **SQLite is the only system of record.** `bookmark_vectors` today, Wax / `sqlite-vec` / USearch tomorrow are
  rebuildable indexes over it; losing one is harmless, and a `.wax` file would never be synced.
- **`Embedder` returns a model id.** That is what keeps vectors compatible across devices and platforms: a chunk
  embedded by another model is re-embedded, not silently searched.
- **What exists**: `DB`, `HistoryStore`, `SettingsStore` (`six/Data/`, `six/Browser/History.swift`), and for
  bookmarks the `Embedder` protocol with `ContextualEmbedder` behind it and `BookmarkStore` as the retrieval layer
  (`six/Bookmarks/`, [bookmarks.md](bookmarks.md)). `Retrieval` is not a protocol yet — the BLOB scan lives inside
  `BookmarkStore.vectorSearch`, one function to swap. `SyncEngine` is not there. `BookmarkStore` imports
  NaturalLanguage and Accelerate only through the embedder and the dot product; the rest is Foundation + GRDB.

## The seams, and what is still open

| seam | Apple | Linux | note |
|---|---|---|---|
| Web | `WebPage` (exists) | WebKitGTK / CEF | the most expensive seam; a Linux front is a different UI anyway, so in practice this is "keep the model out of the views", which is already the case |
| Embedder | `NLContextualEmbedding` (built; per-script spaces) | llama.cpp, ONNX | model ids + re-embedding is what is built: every vector carries its model, a query only meets its own |
| Retrieval | BLOB scan in Swift (built) | the same, then `sqlite-vec` / USearch | `sqlite-vec` needs an own SQLite build on macOS (the system one has extension loading compiled out — [bookmarks.md](bookmarks.md#the-index)); on Linux it just loads |
| Sync | SQLiteData's `SyncEngine` over CloudKit | no-op / own server | without an Apple account a Linux build cannot reach iCloud at all; accept that |
