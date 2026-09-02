# Deep research

This is what the strip was for. An agent is asked to look into a question; it
opens the sources **side by side**, and writes the answer into a document that
stands in the same strip as its first column — with links back to the very
sentences that earned them.

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│  Document    │  aviasales   │  tutu.ru     │  s7.ru       │  ← one workspace,
│  (markdown)  │  OVB → ALA   │  OVB → ALA   │  OVB → ALA   │    "Tickets to KZ"
└──────────────┴──────────────┴──────────────┴──────────────┘
```

The workspace *is* the result: it stays open, survives a relaunch, and can be
come back to.

## Starting a run

- **Research…** in the agent panel (`⌘⇧A`): the question, how many sources to
  open, and the preset itself — visible and editable, with a **Reset**;
- `research: …` or `/research …` on the `⌘K` line.

A workspace named after the question is created, with a document in it carrying
the question as its heading, and the agent is sent the task.

While it runs, a spinner sits beside the document's name in the top bar and says
what the agent is doing. At the end it reads *done `<time>`*, *stopped* or the
error.

A question asked while a research workspace is on screen is a **follow-up** and
continues the same document.

::: tip The bounds are words, not numbers in code
How many sources to open and how deep to go are sentences in a preset you can see
and rewrite.
:::

## Documents

A document is a column like any other: the same width, the same focus, the same
moves between workspaces, the same overview, the same saved session. In the top
bar, where a page has its address, a document has **Edit the Markdown /
Preview**.

| | |
|---|---|
| `⌘⇧N` | a new document |
| **New Document** in the strip's or a column's context menu | the same |
| `⌘S` / `⌘⇧S` | save / save as `.md`, `.html` or `.pdf` |

Until it is saved explicitly a document lives in the application's own folder and
survives a relaunch; closing the window deletes it. **Save As** is for what is
worth keeping.

A link clicked in the preview never navigates the document away: it focuses the
window that already shows that page (scrolling to the passage), or opens it next
door.

You can type in the document while the agent appends to it. The agent writes **by
section** and does not rewrite a section a person has edited — enough for one
person and one agent.

## Highlights and citations

A citation should point at the sentences that earned it, not at a page in
general.

`⌥⇧H` highlights what you selected. The agent does the same by itself, and not by
quoting: a model that retypes a passage mis-types it, and then nothing matches.
It picks the **numbers** of the paragraphs, and the browser anchors them itself.

A highlight survives the page being closed and reopened, and belongs **to the
page, not to the window**: it comes back next week whether or not that research
strip still exists. **File ▸ Remove Highlights on This Page** clears one page's.

If a paragraph cannot be found after a reload, an orange highlighter appears
beside the address with the reason — and the quote and the link in the document
stay either way: the evidence outlives the page.

::: warning Where a highlight will not work
A PDF shown by the built-in viewer; text drawn on a canvas (Google Docs and
friends); text inside cross-origin iframes; pages that rewrite themselves on
every visit. In all of these VI says so rather than highlighting approximately.
:::

The link written into the document is a text fragment (`#:~:text=…`), which any
modern browser follows, not only this one.
