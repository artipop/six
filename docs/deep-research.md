# Deep research

Deep research is what the strip is for. An agent asked to research something opens the sources side by side, and
the answer it writes is **a document that is a window in the strip** — next to the pages it came from, saved with
everything else, exportable like a page, with citations that point at the sentences that earned them.

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│  Document    │  aviasales   │  tutu.ru     │  s7.ru       │   ← one workspace, "Tickets to KZ"
│  (markdown)  │  OVB → ALA   │  OVB → ALA   │  OVB → ALA   │
└──────────────┴──────────────┴──────────────┴──────────────┘
     ↑ the answer, with citations back to the windows on its right
```

## Who runs the loop

The agent, not the app. Claude Code / Codex already plan, call tools, retry and summarize; six does not grow a second
planner. The app gives the loop a place to work (a workspace), the tools to work with, and a surface to write into.
A native loop over the ⌘K model for machines without an agent is in [todo.md](todo.md).

## Starting a run

- **Research…** in the agent panel (`⌘⇧A`): the question, how many sources to open, and the preset itself — editable,
  with a reset; both live in settings.
- `research: …` or `/research …` on the `⌘K` line.

`ResearchCoordinator.start` (`six/Research/`) creates a workspace named after the question (unique within the
profile), a document window in it with the question as its `# ` title and the preview on, and a `ResearchRun` —
question, profile, workspace id, document tab id, source window ids, running flag, status, follow-ups — kept in
`BrowserState.research` and so in the snapshot (`isRunning` is reset on relaunch; nothing survives a turn). Then it
sends the preset to the agent session the panel uses.

The preset asks the agent to `web_search` first, open the sources worth comparing in *this* workspace with
`activate: false` (the user's screen does not jump), write the outline into the document, then fill it in section by
section, citing as it goes, and leave every window open — the workspace is the record. The bounds (how many sources,
how deep) are words in the preset, where the user can see and change them, not numbers in code.

While it runs, tool-call titles stream into `run.status`, shown with a spinner in the document's title bar; the end
writes `done <time>`, `stopped` or `failed` (and replaces the document's "Researching…" line when it failed).
`open_window` into the run's workspace records the window as a source. A question asked while the focused workspace
belongs to a run is a **follow-up**: the follow-up preset points the agent at `read_document` and the same document.

## Document windows

`BrowserTab.content` is `.web(WebPage)` or `.document(TextDocument)` (`six/Documents/`). A document is a column like
any other — widths, focus, moving between workspaces, the overview and persistence all work unchanged. `tab.page`
exists for both kinds: for a document it is a non-persistent `WebPage` that renders the preview and produces the
HTML and PDF export.

- `TextDocument` (`@Observable`): the Markdown, a title read off the first heading (else the first line, else
  "Untitled"), `modifiedAt`, `fileURL` after the first save, and whether the column shows the editor or the preview.
  Sections are `## heading` ranges (code fences skipped), which is what `write_document` works on.
- `DocumentStore` writes the text to `~/Library/Application Support/six/Documents/<id>.md` a second after every edit
  and on quit. The snapshot keeps only `DocumentSnapshot` (id, title, dates, file URL, preview flag) — a long
  document does not ride along in `state.json` on every keystroke. Closing the window deletes the file; Save As is
  for what is worth keeping. History records nothing for a document: it has no URL.
- The preview is `Markdown.page(title:markdown:)`, a renderer of our own: headings, paragraphs, lists (nested,
  checkboxes), quotes, fenced code, tables, rules, links, images, emphasis, and `[n]` citations against
  `[n]: url "title"` definitions, inside a small stylesheet that follows the system appearance. No bundled
  JavaScript library, and no editing inside the rendered view — the editor and the preview swap in place.
- A link clicked in the preview never navigates the document: `DocumentNavigationDecider` cancels it and
  `BrowserState.open(_:from:)` focuses the window that already shows the page (loading the `#:~:text=` fragment so
  it scrolls to the passage) or opens one next to the document.
- Ways to get one: `⌘⇧N`, **New Document** in the strip's and a column's context menu, or `create_document`.

### Two writers

The user types while the agent appends. Section-level writes and "never rewrite a section the user has edited"
(in the preset) are enough for one user and one agent; there is no CRDT.

## Tools

In `BrowserToolCatalog`, so the ⌘K assistant and MCP get the same ones; the full table is in [mcp.md](mcp.md#tools).

| tool | what it does |
|---|---|
| `create_document` | new document window (`title` or `markdown`; optional `workspace`, `profile`, `activate`) → id |
| `write_document` | `mode: replace` the whole text, `append`, or `section` — replace the body of one `## heading`, keeping the heading, or add the section when the heading is new |
| `read_document` | the current Markdown and its section list |
| `cite` | adds `[n]: url "title" — retrieved <date>` (+ the passage as an indented quote) to `## Sources` and returns `[n]`; from a window, a `url`, or a `highlight_id` |
| `highlight_page` | marks the paragraphs that answer a question; returns each as id, text and a `#:~:text=` link |
| `list_page_blocks` `list_highlights` `remove_highlight` | the numbered paragraphs of a page; the highlights stored for a page; delete one |

`document_id` is optional everywhere: the default is the run's document in the on-screen workspace, else the only
document there, else the focused one. The same URL cited twice keeps its number. `list_workspaces` marks documents
with `kind: document` and `six://document/<id>` as the URL.

Writing in sections rather than one final dump is what makes a run watchable: the outline appears first, then each
section fills in while the sources are being read.

## Save As

`Exporter` and `FileCommands` (`six/Documents/Export.swift`). `⌘S` re-saves a document that has a file; otherwise
`⌘S` and `⌘⇧S` both run an `NSSavePanel` (the app is not sandboxed — no bookmarks to keep) with the formats the
window supports:

- document → `.md` (the source), `.html` (the preview page), `.pdf` (`WebPage.exported(as: .pdf())` of the preview)
- page → `.html` (`outerHTML`), `.pdf`, `.txt` (the visible text)

The last folder is remembered in `UserDefaults`, the document's file URL on the document. No `.webarchive`:
`WebPage` has no API for one ([todo.md](todo.md)).

## Highlighted passages

A citation should point at the sentences that earned it, not at a page. Two halves: deciding *which* paragraphs, and
making the mark survive being reopened. Everything is in `six/Highlights/`.

**Choosing them.** Not by asking a model to quote — a model that retypes a passage mis-types it, and then nothing
matches. `HighlightScript.blocks` lists the page's paragraph-ish elements as a numbered list (text and an XPath);
the ⌘K model — the on-device model when ⌘K is set to an agent, since "which of these is about X" is within its reach —
answers with *numbers* and a few words of reason; six anchors those blocks itself. The model never handles the text
it is marking, so it cannot corrupt it. `blocks: "12, 13"` skips the model; `⌥⇧H` does the same for a selection by
hand.

**Anchoring.** The script builds a *text index* — every visible text node under `<body>`, in order — and computes
all three W3C Web Annotation selectors from it, stored together on the `Highlight`:

1. `TextQuoteSelector` — the exact text plus 32 characters of prefix and suffix, kept inside the passage's own
   block so a prefix never glues two paragraphs' words into one no page contains. The primary.
2. `TextPositionSelector` — character offsets into the index. Disambiguates a quote that occurs twice.
3. `RangeSelector` — XPaths to the start and end text nodes with offsets. The last resort, and the first to break.

Re-anchoring (`anchor()`) is a ladder: the exact quote, disambiguated by context and by distance from the recorded
position; the XPath range if what it spans still reads ≥ 0.8 similar; then a fuzzy pass — Levenshtein over candidate
windows seeded by the quote's first distinctive words, near the recorded position on long pages — that gives up
below 0.75 rather than highlight the wrong sentence. This is how Hypothesis survives the real web.

**Drawing.** The CSS Custom Highlight API: one `Highlight` registered as `six-highlight`, painted through
`::highlight()` from an injected `<style>`. It paints `Range`s without touching the DOM, so a React page
re-rendering does not tear anything apart and the page's own scripts see no new nodes. Where the API is missing,
`<mark>` wrappers.

**Dynamic pages.** `HighlightStore.apply` runs after every `didFinishNavigation`. What does not anchor at once is
retried on a `MutationObserver` for five seconds (a lazily hydrated article usually lands in one), then the page
stops; Swift asks for the outcome afterwards and puts a note on the tab — an orange highlighter in the title bar
with the reason: the passage is gone, a PDF in WebKit's viewer, text drawn on a canvas. The document still holds the
quote and the link, so the evidence survives even when the page does not. Never scroll somewhere approximate and
call it the citation.

**In the document.** `Highlight.textFragmentURL` writes `url#:~:text=prefix-,exact,-suffix` (a long quote becomes a
`start,end` range of its first and last words), which any browser that understands text fragments follows; `cite`
with a `highlight_id` puts that link in the source line. Clicking it focuses the source window; WebKit scrolls to
the fragment and `HighlightStore.scroll` lands on the painted range.

**Storage.** `~/Library/Application Support/six/highlights.json`, keyed by URL without its fragment — per page, not
per window, so highlights come back next week whether or not the run still exists. **File → Remove Highlights on
This Page** clears one page's.

**What will not work, and says so:** PDFs shown by WebKit's viewer, text on a canvas (Google Docs and friends),
text inside cross-origin iframes, pages that rewrite their content on every visit.

## Page-side scripts

`ReadablePage`, `BrowserToolCatalog.pageText` and `HighlightScript` all run through `WebPage.six` — `callJavaScript`
in six's own `WKContentWorld`, the way Firefox and Safari run their reader scripts: the page's JavaScript cannot
tamper with what the extractor reads or see the highlight machinery. Why and what it covers is in
[architecture.md](architecture.md#page-side-scripts).
