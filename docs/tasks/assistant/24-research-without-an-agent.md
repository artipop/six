# 24. Deep research on a Mac with no agent

Let Savoia run a deep research itself, on the model ⌘E is set to, for a Mac that has no agent installed.

## Why

`/research` on the ⌘E line hands the question to an ACP agent — Claude Code, Codex or a custom one. The agent is a
separate program with its own subscription, and it does all of the work: searches, opens the sources, reads them,
writes the document, cites and highlights. Savoia only lends it the tools ([deep-research.md](../../deep-research.md)).
On a Mac with no agent, `/research` does nothing at all.

## What to build

A loop of Savoia's own in the agent's place, over whichever language model ⌘E is set to — on-device, Private Cloud
Compute, or a model by key. Savoia calls the same tools the agent would: `web_search`, `open_window`,
`get_page_content`, `write_document`, `cite`, `highlight_page`.

An agent plans for itself; a small model cannot. So the planning is Savoia's code and the model gets one small job
at a time: this page, this heading — write the paragraph. One source at a time, one section at a time, the outline
written into the document first so the person sees it grow, as the preset already asks of an agent.

## First, before the loop

Measure what the on-device model can do with one page and one heading. If it cannot write a usable paragraph from a
page, say so and stop: the feature is then "needs a larger model", and a loop would only hide that. The on-device
model was not available on the dev Mac in October 2026 (Apple Intelligence not set up) — check that before
planning the sitting, or measure on a model by key and say which.

## Done when

A question is answered into a document with citations and highlights on a Mac with no agent, and
deep-research.md records the model, the time and the number of sources. `/research` chooses the agent when ⌘E is
set to one and this loop otherwise, without asking — the rule `highlight_page` already follows.
