# 24. Deep research for a Mac with no agent, and a run saved as one file

Two additions to deep research ([deep-research.md](../../deep-research.md)), independent of each other.

## A run without an agent

`/research` on the ⌘E line hands the question to an ACP agent — Claude Code, Codex or a custom one — which searches,
opens sources, writes the document and cites. A Mac with none of those installed has no deep research at all.

The addition is a loop of Savoia's own over the model ⌘E is set to (on-device, Private Cloud Compute, a model by
key): the same steps the preset describes, driven by Savoia calling its own tools — `web_search`, `open_window`,
`get_page_content`, `write_document`, `cite`, `highlight_page` — instead of an agent calling them. Smaller models
do less per step, so the loop does the planning: one source at a time, one section at a time.

Measure first what the on-device model can do with one source and one section; if it cannot write a usable
paragraph from a page, say so and stop — the feature is then "needs a larger model", not a loop.

## A run as one HTML file

A finished run is a document tab and the tabs of its sources. Export writes the document
(`Savoia/Documents/Export.swift`); the sources stay behind as addresses. The addition is one self-contained `.html`:
the document, and under it each cited source's readable copy (`ReadablePage`) with the highlighted passages marked,
so the file can be sent to someone or kept after the pages change.

## Done when

Each is its own commit. The first: a question answered into a document with citations on a Mac with no agent, with
the model, the time and the number of sources written into deep-research.md. The second: Save As offers the format
and the file opens in Safari with its highlights visible.
