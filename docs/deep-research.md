# Deep research

*Built: phases 1–5 below. Phase 6 (a native loop without an agent, one-file export) is in [todo.md](todo.md).
The design is kept as written; **How it is built** at the end says where each piece landed.*

Deep research is what the strip is already for. An agent asked to research something opens the sources side by side —
that part works today ([mcp.md](mcp.md)) — but the answer it writes lands in the agent panel, a chat log that scrolls
away. The missing half is a place to write: **a document that is a window in the strip**, next to the sources it came
from, saved with everything else and exportable like a page.

A finished run should leave a workspace that looks like this:

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│  Document    │  aviasales   │  tutu.ru     │  s7.ru       │   ← one workspace, "Tickets to KZ"
│  (markdown)  │  OVB → ALA   │  OVB → ALA   │  OVB → ALA   │
└──────────────┴──────────────┴──────────────┴──────────────┘
     ↑ the answer, with citations back to the windows on its right
```

## Who runs the loop

The agent, not the app. Claude Code / Codex already plan, call tools, retry and summarize; six should not grow a
second planner. The app's job is to give the loop a place to work (a workspace), the tools to work with, and a
surface to write into. A native loop over the ⌘K assistant model is a later option for people without an agent
installed (see the phases below) — the tools are the same, only the driver differs.

## The pieces

### 1. Document windows

A column whose content is text rather than a page. `BrowserTab` grows a content case instead of always owning a
`WebPage`:

```swift
enum TabContent {
    case web(WebPage)
    case document(TextDocument)   // markdown source + a WebPage for the rendered preview
}
```

Everything the layout does — widths, focus, moving between workspaces, the overview, persistence — keeps working,
because a document is just another column. What changes:

- `TextDocument`: markdown source, a title (first heading, or "Untitled"), a modified date, an optional file URL once
  it has been saved. `@Observable`, so autosave and the title bar follow it.
- The view: `TextEditor` for the source, a `WebPage` for the preview (markdown → HTML with a small bundled
  stylesheet). Editing and preview swap in place — the document window keeps its column. Rendering through WebKit
  costs nothing extra (it is a browser) and makes export to HTML and PDF fall out of the same path.
- Persistence: documents live in `~/Library/Application Support/six/Documents/<id>.md`, and the snapshot keeps the id,
  the title and the column it sits in. Big text does not belong in `state.json`, which is rewritten on every change.
- History records nothing for a document window; it has no URL.

### 2. Tools for writing

| tool | what it does |
|---|---|
| `create_document` | new document window (`title`, optional `workspace`, `profile`, initial `markdown`) → id |
| `write_document` | `replace` the whole text, `append` to it, or replace one `## section` by heading |
| `read_document` | the current text back, so an agent can revise what it (or the user) wrote |
| `cite` | append a source line — title, URL, retrieved-at, optionally the passage — and return the `[n]` to use inline |
| `highlight_page` | mark the paragraphs of a window that answer a question, and hand back anchors to cite |

`write_document` in sections, rather than one final dump, is what makes a run watchable: the outline appears first,
then each section fills in while the sources are being read. The user can read the document as it grows, and can edit
it — the agent appends below the cursor's section rather than overwriting a paragraph the user is typing in.

### 3. Save As

A document is worth nothing if it can only live in the app. `⌘S` / **File → Save As…** over an `NSSavePanel` (the app
is not sandboxed, so no bookmarks to keep):

- document window → `.md` (the source), `.html` or `.pdf` (through the preview page)
- web window → `.webarchive` (`createWebArchiveData`), `.html` (source), `.pdf` (`WebPage`'s PDF), `.txt`
- remembering the last folder, and the document's file URL after the first save, so `⌘S` is a plain re-save afterwards

This is a browser feature, not a research feature — hence its own entry in [todo.md](todo.md). Deep research just
needs it to exist.

### 4. Highlighted passages

A citation should point at the sentences that earned it, not at a page. Two halves: deciding *which* paragraphs, and
making the mark survive being reopened.

**Choosing them.** Not by asking a model to quote. A model that retypes a passage mis-types it, and then nothing
matches. Instead six extracts the page's text as a numbered list of blocks — one entry per paragraph-ish element, with
its text and a selector — asks the model *which numbers* answer the question, and anchors the numbers itself:

```
12: Прямые рейсы Новосибирск — Алматы выполняет S7 …
13: Багаж 23 кг оплачивается отдельно …
→ model returns [12, 13] with a one-line reason each
```

The model never handles the text it is marking, so it cannot corrupt it. `highlight_page` runs this pass with the
⌘K model (on-device is enough for "which of these is about X") and returns anchors the agent can pass to `cite`.
A human doing it by hand — select, `⌥⇧H` — makes the same kind of anchor.

**Anchoring.** Store the W3C Web Annotation selectors, all of them, and re-anchor with a ladder on the way back
(this is how Hypothesis survives the real web):

1. `TextQuoteSelector` — the exact text plus ~32 characters of prefix and suffix. Survives reflow, ads, an inserted
   paragraph. The primary.
2. `TextPositionSelector` — character offsets into the normalized page text. Cheap, and disambiguates a quote that
   occurs twice.
3. `RangeSelector` — an XPath/child-index path to start and end nodes. The last resort, and the first to break.
4. Fuzzy match — an approximate search (bitap) around the recorded position when the exact quote has drifted by a
   word. Below a similarity threshold, give up rather than highlight the wrong sentence.

**Drawing it.** The CSS Custom Highlight API (`CSS.highlights`, `::highlight()`): it paints `Range`s without touching
the DOM, so a React page re-rendering does not tear our `<span>`s apart and the page's own scripts see nothing. Where
it is missing, fall back to wrapping spans.

**Dynamic pages** are the hard part, and the honest answer is a budget rather than a guarantee. Anchor on
`didFinishNavigation`; if the quote is not there, watch with a `MutationObserver` for a few seconds (a lazily hydrated
article usually lands in one) and try again on each batch; then stop. If it never anchors, the document still holds
the quote and the link — the evidence survives even when the page does not — and the window shows a quiet note that
the passage is no longer on the page. Never scroll somewhere approximate and call it the citation.

**In the document.** A citation is written as a portable link — `[quote](url#:~:text=prefix-,start,end,-suffix)` —
so it works in any browser that understands text fragments (WebKit does), and carries our anchor alongside it for
the precise in-app jump. Clicking it focuses the source window and scrolls to the highlight; if the window was
closed, it opens again with the fragment doing the work.

**Storage.** Highlights are per URL, not per window, and live in a file of their own (`highlights.json`, like
history): they should come back when the page is opened next week, whether or not the research run still exists.

**What will not work, and should say so:** text drawn on a canvas (Google Docs and friends), PDFs shown by WebKit's
own viewer, text inside cross-origin iframes, and pages that rewrite their content on every visit. Detect and report
rather than pretend.

### 5. The run

A **run** is a named workspace plus a prompt preset. Starting one (a "Research…" item in the agent panel, or ⌘K
prefixed with a question) does:

1. Create the workspace, named after the question, in the current profile; create the document window in it.
2. Hand the agent a preset that says: `web_search` first, open the sources worth comparing in *this* workspace with
   `activate: false` (the user's strip does not jump while it works), read them, write the outline into the document,
   then fill it in section by section, citing as you go.
3. Leave everything open. The workspace is the record: sources on the right, the answer on the left, and the strip
   scrolls through exactly what the agent looked at.

State to keep on the run (in the snapshot, so it survives a relaunch): the question, the workspace, the document id,
the source window ids, and whether it is still going. That is enough to show a progress line in the document's title
bar and to let a follow-up question continue the same document instead of starting a new one.

Bounds belong in the preset, not in the code: how many sources to open, how deep to follow links, when to stop. A
number the user can see and change beats a heuristic.

## Phases

| phase | what ships | |
|---|---|---|
| 0 | `web_search`, page reading, workspaces, the agent panel with MCP | done |
| 1 | document windows: `TabContent`, `TextDocument`, editor + preview, persistence | done |
| 2 | `create_document` / `write_document` / `read_document` / `cite`; the agent can write | done |
| 3 | Save As for both kinds of window, `⌘S`, last-folder memory | done |
| 4 | the run: preset, named workspace, progress, follow-ups into the same document | done |
| 5 | highlights: the numbered-block pass, the selector ladder, `CSS.highlights`, `highlights.json`, `⌥⇧H` by hand | done |
| 6 | optional — a native loop on the ⌘K model for machines with no agent; export a run as one HTML file with its sources inlined | not built |

Phases 1–3 are useful on their own: notes in the strip and a working Save As are worth having whether or not an agent
ever writes into them.

## Open questions

- **Markdown rendering.** A small renderer of our own, or markdown → HTML in the preview page? The preview page wins
  on effort and on export, and loses if the document ever needs live editing *inside* the rendered view.
- **Two writers.** The user types while the agent appends. Section-level writes and "never touch the section the
  cursor is in" is probably enough; a real CRDT is not worth it for one user and one agent.
- **Where the document sits.** Pinned to the left end of its workspace, or wherever the user drags it? Pinning is one
  line at insert time and can be undone by moving the column, which is the niri answer: nothing is special.
- **Citations that survive.** `[n]` back to a window id is fine while the window is open. Once it is closed the link
  should still resolve — so `cite` should write the URL, not the id, and the window id is only a convenience.
- **When the passage is gone.** Show the quote from the document and say the page changed, or try the Wayback
  Machine for the version that was read? The second is a network call and a dependency; the first is honest and free.

## How it is built

**Document windows** (`six/Documents/`). `BrowserTab.content` is `.web(WebPage)` or `.document(TextDocument)`;
`tab.page` exists for both — for a document it is a non-persistent `WebPage` that renders the preview and produces
the HTML/PDF export. `TextDocument` is `@Observable`: the text, a title read off the first heading, `modifiedAt`,
`fileURL` after the first save, and whether the column shows the editor or the preview. `DocumentStore` writes the
text to `~/Library/Application Support/six/Documents/<id>.md` a second after every edit (and on quit); the snapshot
keeps only `DocumentSnapshot` (id, title, dates, file URL, preview flag) on the `TabSnapshot`. Closing the window
deletes the file — Save As is for what is worth keeping. The preview is `Markdown.page(title:markdown:)`, a renderer
of our own (headings, lists, quotes, fenced code, tables, links, images, emphasis, `[n]` citations against
`[n]: url "title"` definitions) inside a small stylesheet that follows the system appearance. The open question was
answered the cheap way: the preview page wins, and there is no editing inside the rendered view. A link clicked in
the preview never navigates the document — `DocumentNavigationDecider` cancels it and `BrowserState.open(_:from:)`
focuses the window that already shows the page (loading the `#:~:text=` fragment so it scrolls to the passage) or
opens one next to the document. `⌘⇧N`, the strip's and a column's context menu, or `create_document` open one.

**Tools** — in `BrowserToolCatalog`, so the ⌘K assistant and MCP get the same ones; the table is in
[mcp.md](mcp.md#tools). `write_document` works on `## sections` through `TextDocument.sections` (heading ranges,
fences skipped); `mode: section` keeps the heading and replaces the body, or appends the section when the heading
is new — the outline-first, fill-as-you-read shape the preset asks for. `document_id` is optional: the default is
the run's document in the on-screen workspace, else the only document there. `cite` writes to `## Sources` as
`[n]: url "title" — retrieved <date>` with the passage as an indented quote underneath; the same URL cited twice
keeps its number. `list_workspaces` marks documents with `kind: document`.

**Save As** (`Exporter`, `FileCommands`). `⌘S` re-saves a document that has a file, otherwise both `⌘S` and `⌘⇧S`
run an `NSSavePanel` with the formats the window supports — a document as `.md` (source), `.html` (the preview
page) or `.pdf` (`WebPage.exported(as: .pdf())` of the preview); a page as `.html` (`outerHTML`), `.pdf` or `.txt`.
The last folder is in `UserDefaults`. No `.webarchive`: `WebPage` has no API for one ([todo.md](todo.md)).

**The run** (`six/Research/`). `ResearchCoordinator.start(question)` creates a workspace named after the question
(unique within the profile), a document window in it (preview on, `# question` as its title), a `ResearchRun` in
`BrowserState.research` (question, profile, workspace id, document tab id, source window ids, running flag, status,
follow-ups — saved in the snapshot, `isRunning` reset on relaunch), and sends the preset to the ACP session the
agent panel uses. Tool-call titles stream into `run.status`, shown in the document's title bar with a spinner; the
end writes `done <time>` / `stopped` / `failed`. `open_window` into the run's workspace records the window as a
source. A question asked while the focused workspace belongs to a run is a follow-up: the follow-up preset points the
agent at `read_document` and the same document. Ways in: **Research…** in the agent panel (question, source count,
the preset itself editable and reset-able; both live in settings), or `research: …` / `/research …` on the ⌘K line.

**Highlights** (`six/Highlights/`). `HighlightScript` is one JavaScript library run as function bodies through
`callJavaScript` (no `await` there — the API runs a plain function). It builds a *text index* — every visible text
node under `<body>` in order — and computes all three selectors from it: `TextQuoteSelector` (exact + 32
characters of context, kept inside the passage's own block so a prefix never glues two paragraphs' words together),
`TextPositionSelector` (offsets into the index) and `RangeSelector` (XPaths to the start and end nodes). `anchor()`
is the ladder: exact quote, disambiguated by context and by distance from the recorded position; the XPath range if
it still reads ≥ 0.8 similar; then a fuzzy pass (Levenshtein over candidate windows seeded by the quote's first
words, near the recorded position on long pages) that gives up below 0.75. Painting is `CSS.highlights` under one
`Highlight` named `six-highlight` (`::highlight()` in an injected `<style>`), `<mark>` wrapping only where the API is
missing. `HighlightStore` keeps `~/Library/Application Support/six/highlights.json` keyed by URL-without-fragment
and re-applies on every `didFinishNavigation`; the page keeps retrying missing ones on a `MutationObserver` for five
seconds, the store asks for the outcome afterwards and puts a note on the tab (an orange highlighter in the title
bar with the reason) — a passage that is gone, a PDF in WebKit's viewer, text on a canvas. `highlight_page` runs
the numbered-block pass: `blocks()` lists paragraph-ish elements with their text and an XPath, the ⌘K model (or the
on-device model when ⌘K is set to an agent) answers with numbers, six anchors those blocks. `⌥⇧H` does the same
for a selection. `Highlight.textFragmentURL` writes the `#:~:text=prefix-,exact,-suffix` link (a long quote becomes
a `start,end` range); `cite` with a `highlight_id` puts that link in the source line, so the citation points at the
sentences in any browser and the in-app jump (`HighlightStore.scroll`) lands on the painted range.
