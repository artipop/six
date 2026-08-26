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

`history.json` is a stopgap — the whole file is rewritten on every visit and everything sits in memory, which is why
it is capped at 5000 entries ([architecture.md](architecture.md#persistence)). The step that matters is the one after:
page text and embeddings for retrieval over what was read. One local store for visits, page content, chunks and
vectors — SQLite through the system `SQLite3` module (macOS and Linux, no dependency to fight the SDK override with),
FTS5 for titles and text, vectors as blobs with a brute-force cosine pass (fine to ~100k chunks) or `sqlite-vec` if it
ever isn't. `HistoryStore`'s interface stays; only the backend changes. The app-state snapshot stays JSON — that is
one small document, not a table.

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Downloads UI once `WKDownload` exists: where a file went, and a way to open it.
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
