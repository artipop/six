# Bookmarks

A bookmark in six is three things: a row, a readable file, and a place in a vector index — so that the page is
kept, can be read without the site, and can be found by what it was about rather than by its title.

```
⌘D / star / add_bookmark
   │
   ▼
ReadablePage.extract      in the page: main content → Markdown + title, excerpt, site, image, language
   │
   ├─▶ Profiles/<name>/Bookmarks/<slug>-<id8>.md     the readable copy, YAML front matter + Markdown
   ├─▶ bookmarks(id, profileID, url, title, …)         the record, in six.sqlite
   ├─▶ bookmark_chunks(bookmarkID, ord, text)          passages of ~900 characters, chunk 0 = title + excerpt
   └─▶ bookmark_vectors(chunkID, profileID, model, embedding BLOB)   one unit vector per passage, in the background
```

## Files

Every profile has its own folder, `~/Library/Application Support/org.deffun.six/Profiles/<name>/`, with `Bookmarks/` and the
agents' `Scratchpad/` side by side. The folder is named after the profile, so renaming one in the profile menu moves the
folder with it (`BrowserState.renameProfile`) — otherwise everything saved under the old name would be orphaned. The agents' default working directory is the scratchpad, *not* the profile folder:
that way a question about something saved goes through `search_bookmarks` (and its vector search) rather than a
`grep` over the working directory, and what a run leaves behind lands in the scratchpad, away from the bookmarks. A
file looks like this:

```markdown
---
title: "Pilaf - Wikipedia"
url: https://en.wikipedia.org/wiki/Pilaf
site: "en.wikipedia.org"
image: https://upload.wikimedia.org/…/Afghan_Palo.jpg
language: en
profile: "Work"
saved: 2026-08-26T11:12:32Z
id: 9F73C504-…
---

# Pilaf

From Wikipedia, the free encyclopedia
…
```

The front matter is enough to rebuild the row; the body is the page as Markdown — headings, paragraphs, lists,
quotes, code, links (absolute), tables, and images at least 120 px on a side. `ReadablePage` (`six/Bookmarks/`) does the
extraction in the page itself, read-only: `<article>` / `<main>` / `[role=main]` when the page says where the content
is, otherwise the element that gathers the most paragraph text (a Readability-style score with a decaying weight up the
tree); navigation, asides, footers, forms, hidden nodes and anything whose id or class says *comment*, *share*,
*sidebar*, *cookie*, *newsletter*, … are dropped. It is our own ~150 lines rather than Mozilla's Readability.js; if it
starts losing on real pages, that library is the drop-in.

Bookmarking a page again refreshes its copy under the same id and file. Removing the bookmark removes the file;
removing the profile removes the folder. The database is the system of record; the file is the human copy.

## Embeddings

**Foundation Models has no embedding API** (checked in the macOS 27 SDK, 26A5406c). The embedder is
`intfloat/multilingual-e5-small` run through **MLX** (`MLXEmbedder`, `six/Bookmarks/MLXEmbedder.swift`, over
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)'s `MLXEmbedders`): 118 M parameters, 384 dimensions, about a
hundred languages in *one* space — «плов» and *pilaf* land next to each other, which is the whole point. The weights
(~470 MB, fp32 safetensors) come from the Hugging Face Hub on first use into `~/Library/Application Support/org.deffun.six/Models`
and never leave the Mac afterwards; the download shows in the bookmarks window's footer and in the `list_bookmarks`
status. Three things E5 needs, all in `MLXEmbedder`: a role prefix on every text (`query: ` for a question,
`passage: ` for a chunk — hence `EmbeddingRole` on the `Embedder` protocol), **mean pooling** (set explicitly: the
snapshot's `1_Pooling/config.json` doesn't reach the factory, and the CLS pooler it falls back to puts every sentence
within a few percent of every other), and L2 normalisation. Texts are cut at 510 tokens and batched by 32, sorted by length so a batch pads little.

Saving never waits for any of this: `add` extracts, writes the file and the row and returns (0.2 s); the embedding
runs in the store's queue, off the main actor — the adapters are `nonisolated` on purpose, since the target defaults
every type to the main actor and a main-actor tokenizer would parse `tokenizer.json` and encode every chunk on the
UI thread. Throughput on an M-series Mac: a 118-passage Wikipedia page embeds in ~4 s in a **Release** build (plus
~3 s of warm-up the first time) and ~14 s in **Debug** — Xcode builds package dependencies without optimisation, and
MLX's graph code at -O0 is the difference. The star spins while the page is indexed; the page is bookmarked and
searchable by title from the first second.

The hub client and the tokenizer are adapted by hand (`HubDownloader`, `TransformersTokenizerLoader`) rather than
through mlx-swift-lm's `MLXHuggingFace` macros — those pull in `MLXFoundationModels`, a third-party
`LanguageModel`, which is exactly what the SDK override is protecting us from ([build.md](build.md)).

`ContextualEmbedder` — Apple's `NLContextualEmbedding`, 512 dimensions, no download — stays as the zero-dependency
alternative, but its models are per *script* (Latin, Cyrillic, CJK) in unaligned spaces: a Russian query never finds
an English page. That is what it was replaced for. Both are `Embedder` conformers; every vector carries its model id
and every bookmark the *index signature* (`<modelID>@<indexVersion>`), so switching embedders re-embeds everything.

Small has a price: within a language the ranking is right, across languages it is right for topics and shaky for
details (an English question about a Russian paragraph's sugar can lose to an unrelated English page). The next
model up is one line — `MLXEmbedder.configuration` to `multilingual-e5-base` or `bge-m3` — at 2–4× the download.

`SIX_EMBED_SELFTEST=1` on launch prints the tokenizer's view of a few sentences, the pooling strategy and pairwise
cosines to stderr — the way the CLS-pooling bug was found.

## The index

Vectors live in **sqlite-vec** `vec0` tables inside `six.sqlite`, one per vector dimension — `bookmark_vec_384` —
with `chunk_id TEXT PRIMARY KEY`, `profile_id` as a **partition key** (a per-profile search is a filtered KNN, not a
post-filter), `model` as metadata and `distance_metric=cosine`. `BookmarkStore` creates the table on first use for
whatever dimension the embedder has. The search is hybrid: the query vector's KNN (`WHERE embedding MATCH ? AND k = ?
AND model = ? [AND profile_id = ?]`), the best passage of each bookmark as its hit and snippet, merged with a
substring pass over title, address and excerpt — every word of three letters or more has to be there, so a stray «в»
or *in* doesn't count — that nudges a bookmark the two agree on. The score shown is `1 − cosine distance`; E5 keeps
everything above ~0.7, so the *ranking* is the signal, not the number.

**How sqlite-vec got in.** The SQLite that ships with macOS is built with `SQLITE_OMIT_LOAD_EXTENSION`:
`sqlite3_auto_extension` answers `SQLITE_MISUSE` and there is no `load_extension`. What does work is calling the
extension's entry point on each connection by hand — `sqlite3_vec_init(db, …)` — which is what
[sqlite-vec-data](https://github.com/mhayes853/sqlite-vec-data) (a SQLiteData/StructuredQueries companion that
vendors `sqlite-vec.c`) does in `Database.loadSQLiteVecExtension()`; `AppDatabase` runs it from GRDB's
`prepareDatabase`. The package's typed `Vec0` tables aren't used — the table name depends on the embedder's
dimension, so the KNN is plain SQL through GRDB — but the loader and the vendored C are its. The earlier float32-BLOB
table scanned with `vDSP` is gone (migration v4 drops it; the index is rebuilt from the chunks).

## Keeping them fresh

Pages change, and so do our models. Two things keep the index honest:

- **Re-embedding.** Every vector carries the model that made it, and every bookmark the *index signature* it was
  embedded under — `<embedder.modelID>@<BookmarkStore.indexVersion>`. Switching the embedder or bumping
  `indexVersion` (a chunking or pooling change) makes `resumeIndexing()` re-embed everything on the next launch.
- **Re-reading.** On a schedule (Bookmarks → **Re-read Saved Pages**: never / daily / weekly (default) / monthly) the
  store looks for bookmarks whose last read is older than that — thirty seconds after launch, then hourly — and
  reloads each one off screen in a `WebPage` of its own with the profile's cookie jar, so a page behind a login is
  read as the user sees it. One page at a time, two seconds apart, oldest first. The readable text is hashed
  (SHA-256, `contentHash`); the same hash only stamps `refreshedAt`, a different one rewrites the file and the
  chunks and re-embeds. A page that won't load keeps its old copy and records `refreshError` (an orange
  arrow in the list). **Refresh Bookmark** / **Refresh *Profile* Bookmarks** in the menu, *Refresh Now* in the list
  and the `refresh_bookmark` tool do the same on demand.

## Where it shows

- **Bookmarks menu**: *Add Bookmark* `⌘D` (becomes *Remove Bookmark* on a saved page), *Show Bookmarks…* `⌘⌥B`,
  **Assistant Searches: This Profile / All Profiles**, the refresh commands and interval, the profile's 15 most recent.
- **The star** in the top bar, against the right edge of the address field: filled as soon as the row exists —
  saved is saved, and the embedding that follows says so in the tooltip rather than by spinning, which would read as
  "still saving". It sits with the address rather than out among the rail's buttons, because both are about the one
  page you are reading.
- **`⌘⌥B`** (`BookmarksView`): the profile's or everyone's bookmarks, a search field that searches by meaning as you
  type (with the matching passage and a score), double-click to open, *Show File in Finder*, ⌫ to remove.
- **The start page's field**, without being asked: what you saved comes back as the top rows under it, matched by
  meaning against the same index — [start-page.md](start-page.md#your-own-pages-first).

## The assistant and the agents

The scope — this profile or all — is one setting (`bookmarks.scope`), set from the Bookmarks menu, the ⌘K model
menu or the agent panel's header. It is what `list_bookmarks` and `search_bookmarks` return when the caller doesn't
say; a `profile` argument (a name, or `all`) overrides it per call. Tools:

| tool | |
|---|---|
| `list_bookmarks` | newest first: title, URL, site, profile, date, id, index status (`profile`, `limit`) |
| `search_bookmarks` | hybrid search; each hit with its passage and score (`query`, `profile`, `count`) |
| `read_bookmark` | the Markdown file, front matter included (`bookmark_id` — a prefix is enough, `max_chars`) |
| `add_bookmark` | save a window's page (`window_id`, default the focused one) |
| `refresh_bookmark` | re-read the page now; answers *Updated* or *Unchanged* |
| `remove_bookmark` | delete the bookmark and its file |

The ⌘K assistant (on-device, PCC, Claude) gets them as Foundation Models tools and is told to search the bookmarks
when the question is about something the user saved; ACP agents get them as `mcp__six__*` ([mcp.md](mcp.md)).
