# Deep research

An agent is asked to look into a question; it opens the sources as tabs in one
group, and writes the answer into a document that stands first in that same
group — with links back to the very sentences that earned them.

```
┌──────────────┬──────────────┬──────────────┬──────────────┐
│  Document    │  aviasales   │  tutu.ru     │  s7.ru       │  ← one group,
│  (markdown)  │  OVB → ALA   │  OVB → ALA   │  OVB → ALA   │    "Tickets to KZ"
└──────────────┴──────────────┴──────────────┴──────────────┘
```

The group *is* the result: it stays open, survives a relaunch, and can be come
back to. Close its last tab and Savoia asks whether to delete the group named after
the question: for one run the answer is keep, for another it is delete, and only
the person who started it knows which.

## Starting a run

On the `⌘E` line: `research: …` and the question, or `/research` — the action
stands in the line as a chip — then the question and `⏎`. The run is carried out
by the agent chosen for the line.

A group named after the question is created, with a document in it carrying
the question as its heading, and the agent is sent the task.

While it runs, a spinner sits beside the document's name in the bar under the tabs and says
what the agent is doing. At the end it reads *done `<time>`*, *stopped* or the
error.

A question asked while a research group is in front is a **follow-up** and
continues the same document.

::: tip The bounds are words, not numbers in code
How many sources to open and how deep to go are sentences in the request's
preset, not numbers in code. The preset cannot be edited from the interface right
now: it was edited in the agent panel, which is not there for the moment.
:::

## Documents

A document is a tab like any other: it moves between groups, stands beside a
page, and is kept in the saved session the same way. In the bar under the tabs,
where a page has its address, a document has **Edit the Markdown /
Preview**.

| | |
|---|---|
| `⌘⇧N` | a new document |
| **File ▸ New Document** | the same |
| `⌘S` / `⌘⇧S` | save / save as `.md`, `.html` or `.pdf` |

Until it is saved explicitly a document lives in the application's own folder and
survives a relaunch; closing the tab deletes it. **Save As** is for what is
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
page, not to the tab**: it comes back next week whether or not that research
group still exists. **File ▸ Remove Highlights on This Page** clears one page's.

If a paragraph cannot be found after a reload, an orange highlighter appears
beside the address with the reason — and the quote and the link in the document
stay either way: the evidence outlives the page.

::: warning Where a highlight will not work
A PDF shown by the built-in viewer; text drawn on a canvas (Google Docs and
friends); text inside cross-origin iframes; pages that rewrite themselves on
every visit. In all of these Savoia says so rather than highlighting approximately.
:::

The link written into the document is a text fragment (`#:~:text=…`), which any
modern browser follows, not only this one.
