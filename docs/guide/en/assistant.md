# The ⌘K assistant

One line at the bottom of the rail: ask about the page you are reading. The
answer floats above it as a card.

The line is out of sight until it is asked for — a bar resting over the bottom of
every page covers what the page put there, which is usually a video's controls.
`⌘K` brings it up, an answer keeps it up, and both go when they are done.

The page goes with the question as context: its title, its address and its text.
What answers is picked in the menu beside the line.

## Which model answers

| | |
|---|---|
| **On-Device** | the system's model; nothing leaves the Mac |
| **Private Cloud Compute** | Apple's cloud, with its guarantees |
| **Claude Sonnet 5 / Opus 5** | with an Anthropic API key |
| **OpenAI-compatible** | anything speaking the `/chat/completions` format: OpenAI, a gateway, or llama.cpp and Ollama on this very machine |
| **Claude Code (ACP)**, **Codex (ACP)** | the same line answered by an [agent](/en/agents) — the same session and transcript as the `⌘⇧A` panel |

**OpenAI-compatible** is one menu entry rather than a list of models because what
it points at is a setting: **Model Providers…** holds an endpoint, a model name
and a key. A local server wants no key at all, and an empty field means no
authorization header is sent.

The Anthropic key goes in **Anthropic API Key…**.

::: warning About keys, honestly
Keys are kept in the application's settings. That is enough to work on your own
machine, but it is not a secret store.
:::

## What the assistant can do besides answer

It is given the browser's tools — the same ones the [agents](/en/agents) get: open
a window, navigate, read a page, summarize it, search the web, close or move a
window, search your bookmarks. So "find flights and open three sites side by
side" is not a metaphor; it is what happens.

Which bookmarks it looks in is set by **Bookmarks ▸ Assistant Searches**, or by
the same picker in the model menu: this profile only, or all of them.

## The research command

`research: …` or `/research …` on the `⌘K` line starts
[deep research](/en/research): a workspace of sources and a document the agent
writes into.

## When a model is unavailable

The line says so, with the reason. The remote models can be switched off if the
runtime and the build disagree about their versions; that is checked at launch so
the application does not fall over on the first question.
