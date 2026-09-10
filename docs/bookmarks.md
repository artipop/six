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

The weights arrive fp32 — that is what the snapshot holds — and are **cast to fp16 once loaded**.
Measured on an M2, in Debug, over 64 passages of ~900 characters: 1.0–1.5 s and 470 MB of GPU memory at
fp32, 0.76–0.85 s and 235 MB at fp16. On an 8 GB machine the memory is the half that matters, since MLX
shares it with every WebKit process. The vectors move in the third decimal — cosines from the selftest
change by 0.001 and the norm lands at 0.9998 — which is well under anything cosine distance sorts on, so
an index written before the cast stays valid. `BertModel` casts the attention mask to the embeddings'
dtype for exactly this case and says so in a comment; the graph is fp16 throughout.

Saving never waits for any of this: `add` extracts, writes the file and the row and returns (0.2 s); the embedding
runs in the store's queue, off the main actor — the adapters are `nonisolated` on purpose, since the target defaults
every type to the main actor and a main-actor tokenizer would parse `tokenizer.json` and encode every chunk on the
UI thread. Throughput on an M-series Mac: a 118-passage Wikipedia page embeds in ~4 s in a **Release** build (plus
~3 s of warm-up the first time) and ~14 s in **Debug** — Xcode builds package dependencies without optimisation, and
MLX's graph code at -O0 is the difference. The star spins while the page is indexed; the page is bookmarked and
searchable by title from the first second.

**The model is loaded before anybody asks for it.** Loading the container is ~3 s, and the first question
of a launch used to pay it *after* the debounce — the field simply said nothing for three seconds, which
is what "the embedding is slow" turned out to mean. `Embedder.warmUp()` (nothing by default; `MLXEmbedder`
loads the container) is called from `BookmarkStore.warmUpEmbedder` where a search is about to come from: a
start page taking the keyboard, and the bookmarks window appearing. Two guards keep it honest — a profile
with no bookmarks warms nothing, and neither does a machine that does not have the weights yet, since
`warmUp` resolves the snapshot with `localFilesOnly`, which reads the cache and never the network. A
warm-up is worth a disk read; it is not worth a 465 MB download nobody asked for, and that download stays
where it was, on the first search that means it.

The hub client and the tokenizer are adapted by hand (`HubDownloader`, `TransformersTokenizerLoader`) rather than
through mlx-swift-lm's `MLXHuggingFace` macros — those pull in `MLXFoundationModels`, a third-party
`LanguageModel`, which is exactly what the SDK override is protecting us from ([build.md](build.md)).

`ContextualEmbedder` — Apple's `NLContextualEmbedding`, 512 dimensions, no download — stays as the zero-dependency
alternative, but its models are per *script* (Latin, Cyrillic, CJK) in unaligned spaces: a Russian query never finds
an English page. That is what it was replaced for. Both are `Embedder` conformers; every vector carries its model id
and every bookmark the *index signature* (`<modelID>@<indexVersion>`), so switching embedders re-embeds everything.

Small has a price: within a language the ranking is right, across languages it is right for topics and shaky for
details (an English question about a Russian paragraph's sugar can lose to an unrelated English page). The next model
up is no longer a code edit but a **setting**. `EmbeddingModelChoice` has two rungs — `small` as above and `base`
(`intfloat/multilingual-e5-base`, 278 M parameters, **768** dimensions, ~1.1 GB) — and Settings ▸ General ▸ Bookmarks ▸
**Model for Search by Meaning** picks between them.

**Which one a Mac is offered** is `EmbeddingModelChoice.recommended`, and it reads memory and nothing else: 16 GB or
more gets `base`, everything below gets `small`. The weights are held for as long as six runs, in memory the GPU and
every WebKit process share; at 8 GB, where macOS already sits in its `.warning` band, the bigger model is paid for by
the pages, which is the wrong thing to pay with. Cores are deliberately not in it — the ranking is what `base` buys,
and a slower machine wants it no less. The picker says which one is recommended and lets the other be chosen anyway;
that is the whole design, a recommendation rather than a rule.

What `base` is worth on a real library is **not measured here**: the picker's "ranks a little better between
languages" is the model card's claim and MTEB's, not this repository's. The way to check it is the way the two
thresholds in `PersonalSuggestions` were set — `SIX_PERSONAL_SELFTEST="one; two"` against a library with something in
it, on one model and then the other. Until somebody does that, the recommendation rests on what the sizes cost, which
*is* measured, and not on what they buy.

**The decision is made once.** `SettingsStore.embeddingModel` is nil until six has decided, and the first launch that
asks writes down `settings.embeddingModel ?? BookmarkStore.modelOfExistingIndex(in:) ?? .recommended`. The middle
term is the one that matters: a library already embedded with `small` keeps `small`, whatever this Mac would be
offered today. An update is not allowed to start a 1.1 GB download and a full re-embed on its own — the
recommendation is for a library with nothing to lose.

**Switching** is `BookmarkStore.use(_:)`: a new embedder, the `vec0` table for its dimension created if new, the
queue emptied and every bookmark queued again. It is not a conversion — two models' vectors are never comparable, so
the old ones are left in their own table under their own model id, and switching back costs the time to embed again
and nothing on the disk. The download the new model needs is narrated in the bookmarks window's footer, like the
first one.

`SIX_EMBED_SELFTEST=1` on launch prints the tokenizer's view of a few sentences, the pooling strategy and pairwise
cosines to stderr — the way the CLS-pooling bug was found. `SIX_EMBED_SWITCH=base` works the picker from a terminal
three seconds after launch, which is the only way to exercise the live switch here: the settings page cannot be
clicked by a script on this machine, and the setting itself is left alone, so a restart returns to whatever the user
chose.

## The index

Vectors live in **sqlite-vec** `vec0` tables inside `six.sqlite`, one per vector dimension — `bookmark_vec_384` for
`small`, `bookmark_vec_768` for `base` —
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

**And how it got into the other two fronts, which is the opposite way round.** The SQLite the Linux and Windows
builds link — the system one there, the amalgamation `scripts/six-windows.ps1` compiles here — is built *with*
extension loading, so `sqlite-vec.c` compiles as a loadable extension and every SQLite call inside it goes through
the `sqlite3_api_routines` table it is handed at init. `sqlite3_vec_init(db, nil, nil)` therefore hands it a null
table and crashes; `sqlite3_auto_extension` is the entry point that passes a real one, and it has to run *before* the
first connection is opened. That is the whole of `Vectors.register()` in each front's `SixBrowser`, called from the
line above `AppDatabase.open()`.

`SixCore` itself does not link sqlite-vec, and the dependency is named in `windows/Package.swift` and
`linux/Package.swift` instead — on Linux because `CSQLiteVec` reads the system SQLite headers while adwaita-swift's
`meta-sqlite` vendors its own, and Clang will not hold two definitions of `sqlite3_api_routines` in one compilation
unit (`7806432`). `SixBrowser` imports it `internal`, so the module never reaches `SixUI`, which is the same seam
that already keeps `SixCore` away from Adwaita. Two consequences worth knowing:

- **`AppDatabase` guards on `canImport(Darwin) && canImport(SQLiteVecData)`, not on the second half alone.** Once a
  front puts the package in its graph, `canImport` answers yes while `SixCore` still has no dependency to import
  through, and the build stops on `missing required module 'CSQLiteVec'` three files from anything about vectors.
- **`swift-tagged` is named in both front manifests as a dependency no target uses.** sqlite-data declares it
  unconditionally but SwiftPM prunes it while the `Tagged` trait is off, and sqlite-vec-data enabling that trait is
  not enough to bring it back — the resolve fails outright with `exhausted attempts … 'swift-tagged' unresolved`.
  Naming it does, at the cost of a "not used by any target" warning. Neither manifest's other pins move:
  GRDB 7.11.1, sqlite-data 1.11.0 and structured-queries 0.37.0 are where they were.

`SIX_VEC_SELFTEST=1` answers "does this build actually have a vector index" against the real connection —
`VectorIndex.selfTest` builds a four-wide table, puts three vectors in it and checks that the identical one comes
back first. It is shared, so all four fronts answer it in the same words.

## Off the Mac: the same model, a different road

Windows and Linux have no Metal, so no MLX — and there is no ONNX Runtime a Swift package could link on both. What
they do have is a JavaScript engine with a wasm runtime in it, in a process of its own, which is exactly what
`PageSandbox` (`six/Browser/PageSandbox.swift`) was built for when Bergamot needed one. So the embedder is a program
in an off-screen page rather than a library in the process: `WebEmbedder` drives **transformers.js 3.8.1** over
[`Xenova/multilingual-e5-small`](https://huggingface.co/Xenova/multilingual-e5-small), the ONNX conversion of the very
weights MLX reads.

**Why a vector from either is stamped `multilingual-e5-small`.** Same architecture, same tokenizer, same
`query: `/`passage: ` prefixes, same mean pooling, same L2 normalisation. What differs is arithmetic — fp16 on a GPU
there, int8 on a CPU here — and it moves a cosine in its third decimal, under what the ranking sorts on. The claim is
that the two spaces are comparable, not that the numbers are equal.

What is installed, under `<Application Support>/Embedding` (`EmbeddingStore`, `EmbeddingCatalog`):

| | |
|---|---|
| `runtime@3.8.1/` | transformers.min.js, the ONNX Runtime glue and its wasm — 22 MB, from jsDelivr, digests **written down in the source** because a pinned npm version cannot legitimately change |
| `models/multilingual-e5-small/` | `config.json`, `tokenizer_config.json`, `tokenizer.json`, `onnx/model_quantized.onnx` — 135 MB, from Hugging Face, digests **fetched from its API**, because a file in Git LFS carries its SHA-256 as its object id |
| `six-embed.html`, `six-embed.js` | written on every launch; four kilobytes of generated output is not worth a version file |

Everything is named by a path *relative to the page*, the way `BergamotRuntime` names its own: a Windows path is not a
URL path, and that difference is where half of six's `file:` bugs have lived.

**The one line that had to be measured.** ONNX Runtime's wasm backend does not load its glue with a `<script>` — it
*dynamically imports* `ort-wasm-simd-threaded.jsep.mjs`. A module import from a `file:` document is refused by WebKit
however much file access the view has been given (the static import at the top of the page works; a dynamic one does
not), and what comes back is `no available backend found. ERR: [wasm] TypeError: Importing a module script failed` —
three layers away from anything that mentions a module. Read as text and handed back as a `blob:` URL, the same bytes
import fine, and the wasm is named explicitly beside it because the glue would otherwise resolve it against its own
`import.meta.url`. That is what `env.backends.onnx.wasm.wasmPaths = { mjs, wasm }` is doing in `EmbedderDriver`.

**The shared half.** `BookmarkIndexer` holds the row, the passages, the queue and the search for these fronts;
`TextChunker` holds the cutting rules and `indexVersion` (moved out of `BookmarkStore`, so all four fronts cut a page
the same way); `VectorIndex` holds the `vec0` table, the blob format and the KNN. `BookmarkStore` keeps only the two
halves that are Apple's — the off-screen `WKWebView` that re-reads a page, and the Markdown copy. A bookmark saved on
Windows is a row the Mac reads, re-embeds and ranks.

**`SIX_EMBED_SELFTEST=1`** saves three pages — плов in Russian, pilaf in English, a page about reserved domain names —
into a profile id of its own, embeds them, asks the index four questions and deletes what it wrote. Measured on this
Windows machine (Debug, int8, one wasm thread): the model loads in 3.3 s and a two-passage page embeds in 0.2–0.35 s.
The space is right — `cos(плов_ru, pilaf_en) = 0.841` against `0.771` to the page about domain names, and
`cos(domains_en, domains_ru) = 0.898` — and a Russian question ranks the *English* page above the decoy. The honest
caveat is the other direction: an English question ranks the Russian page and the English decoy within 0.005 of each
other, which is E5's own same-language bias on a three-document corpus rather than anything six does.

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
- **The star** in the top bar, against the right edge of the address field (and drawn only when that field is —
  an empty workspace has no focused window, so there is nothing to save): filled as soon as the row exists —
  saved is saved, and the embedding that follows says so in the tooltip rather than by spinning, which would read as
  "still saving". It sits with the address rather than out among the rail's buttons, because both are about the one
  page you are reading.
- **`⌘⌥B`** (`BookmarksView`): the profile's or everyone's bookmarks, a search field that searches by meaning as you
  type (with the matching passage and a score), ↑ ↓ from the field to walk the rows, double-click to open,
  *Show File in Finder*, ⌘⌫ to remove.
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
