# Deep research — plan

*Not built yet. This is the design; the pieces it needs are tracked in [todo.md](todo.md).*

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
installed (see phase 4) — the tools are the same, only the driver differs.

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
| `cite` | append a source line — title, URL, retrieved-at — from a window id, and return the `[n]` to use inline |

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

### 4. The run

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

| phase | what ships |
|---|---|
| 0 | *done* — `web_search`, page reading, workspaces, the agent panel with MCP |
| 1 | document windows: `TabContent`, `TextDocument`, editor + preview, persistence |
| 2 | `create_document` / `write_document` / `read_document` / `cite`; the agent can write |
| 3 | Save As for both kinds of window, `⌘S`, last-folder memory |
| 4 | the run: preset, named workspace, progress, follow-ups into the same document |
| 5 | optional — a native loop on the ⌘K model for machines with no agent; export a run as one HTML file with its sources inlined |

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
