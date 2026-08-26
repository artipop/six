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

Every profile has its own folder, `~/Library/Application Support/six/Profiles/<name>/`, with `Bookmarks/` and the
agents' `Scratchpad/` side by side. The agents' default working directory is the scratchpad, *not* the profile folder:
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

**Foundation Models has no embedding API** (checked in the macOS 27 SDK, 26A5406c: nothing in the framework's interface
mentions embeddings). What Apple does ship, on device, is `NLContextualEmbedding` in NaturalLanguage: BERT-style
sentence models, 512 dimensions, no network, no key — one model per *script* (Latin, Cyrillic, CJK), each multilingual
within its script. `ContextualEmbedder` (`six/Bookmarks/Embedder.swift`) detects the text's language, picks the
model, mean-pools the token vectors and normalises the result.

The consequence: **the spaces are not aligned across scripts**. A Russian query finds Russian passages and an English
one English passages; «плов» does not find the Pilaf article. The model id is stored with every vector and a query
only searches vectors of its own model, so nothing is silently compared across spaces. The `Embedder` protocol
(`modelID`, `dimension`, `embed(_:)`) is the seam: a cross-lingual remote embedder (Voyage, OpenAI) is a second
conformer, and `BookmarkStore.resumeIndexing()` re-embeds everything whose `embeddingModel` differs from the current
one. Multimodal (search by image) is not there — there is no on-device text–image model in the SDK; the `image` in the
front matter is what a remote multimodal embedder would pick up later.

Assets for a script are downloaded by the system on first use (`requestAssets`); until then, or on a Mac without
Apple Intelligence assets, the bookmark shows *not indexed* with the reason and text search still works.

## The index

Vectors sit in `bookmark_vectors` as float32 BLOBs, one row per passage, keyed by profile and model. Search
(`BookmarkStore.search`) is hybrid: substring matches over title, address and excerpt, merged with a vector pass —
every vector of the query's model (and profile, when scoped) is read and scored by dot product (`vDSP_dotpr`); the best
passage of each bookmark is its hit and its snippet. That is a brute-force scan, and it is fine into the tens of
thousands of passages (a passage is 2 KB; 10 000 of them are 20 MB and a few milliseconds).

**Why not sqlite-vec.** It was the plan, and it was tried: the extension compiles into the app, but the SQLite that
ships with macOS is built with `SQLITE_OMIT_LOAD_EXTENSION`, and there `sqlite3_auto_extension` answers `SQLITE_MISUSE`
— no `vec0` module, on any connection. Getting it means compiling SQLite ourselves (the amalgamation, with the flags
GRDB expects — `COLUMN_METADATA`, `FTS5`, `SNAPSHOT`, …) into the app so GRDB binds to it instead of `/usr/lib`, which
is the route [swift-sqlcipher](https://github.com/skiptools/swift-sqlcipher) takes. Worth it once the scan is too
slow, together with `vec0`'s partition keys (a per-profile KNN instead of a filter); the schema change is one table.
[jkrukowski/SQLiteVec](https://github.com/jkrukowski/SQLiteVec) bundles its own SQLite for the same reason and would
be a second database file, not the one under history.

## Where it shows

- **Bookmarks menu**: *Add Bookmark* `⌘D` (becomes *Remove Bookmark* on a saved page), *Show Bookmarks…* `⌘⌥B`, the
  profile's 15 most recent, and **Assistant Searches: This Profile / All Profiles**.
- **The star** in the top bar: filled when the focused page is saved, a spinner while it is being indexed.
- **`⌘⌥B`** (`BookmarksView`): the profile's or everyone's bookmarks, a search field that searches by meaning as you
  type (with the matching passage and a score), double-click to open, *Show File in Finder*, ⌫ to remove.

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
| `remove_bookmark` | delete the bookmark and its file |

The ⌘K assistant (on-device, PCC, Claude) gets them as Foundation Models tools and is told to search the bookmarks
when the question is about something the user saved; ACP agents get them as `mcp__six__*` ([mcp.md](mcp.md)).
