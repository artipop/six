# The assistant

Six's assistant is not a chat. It is a set of verbs offered where you are already
pointing at something: **text selected on a page**, **a caret in a field**, and
the **`⌘K` line** at the bottom of the rail. One list of actions serves all
three, so a new verb shows up in every one of them at once.

The only conversation with a history left in six is the [agent](/en/agents) panel
on `⌘⇧A`, where the transcript is the work.

## When you select text

A small bar appears over the selection:

| | |
|---|---|
| **Explain** | what this says, in plain language — terms and abbreviations included |
| **Summarize** | the same, shorter: three sentences, or a list where the text is one |
| **What is this?** | for a name, a term or a title |
| **Check this claim** | what it rests on, and what would have to be true for it to be wrong |
| **Ask…** | the caret moves to the `⌘K` line with the selection already the subject |

If the selection is **inside something you can write in** — a comment box, a
message, an editor on the page — the verbs that change text join in: **Fix
Spelling and Grammar**, **Rewrite**, **Make It Shorter**, **Translate to
English**.

## When the caret is in a field

Nothing is sent anywhere while you type: the assistant wakes up only when it is
called. Call it from the bar beside the field, or from the `⌘K` line:

| | |
|---|---|
| **Continue Writing** | carry on from exactly where you stopped |
| **Draft a Reply** | the field is a reply to what is on the page; here is one |
| **Polish What Is Written** | spelling, grammar and punctuation across the whole field, in your words rather than its own |

**Password fields are not read at all** — no content, no caret, no event: the
page drops them before anything reaches six. The same goes for fields that look
like a one-time code or a card number.

## How an answer gets into the page

It never gets there by itself. **Insert** or **Replace** appears under the
answer, and `⏎` on an empty `⌘K` line does the same. The text lands in the field
as if it had been typed, so `⌘Z` takes it back.

## The ⌘K line

The line is out of sight until it is asked for — a bar resting over the bottom of
every page covers what the page put there, which is usually a video's controls.
`⌘K` brings it up, an answer keeps it up, `Esc` sends it away.

Ask freely, in your own words. The line says what the question will be about —
the selection, this field, or the whole page — and while it has focus the same
verbs stand above it as in the bar over the text: the bar is for the mouse, the
line is for the keyboard, the list is one.

`⏎` sends the question. `⏎` on an empty line applies the answer already there.

## Turning all of it off

**Settings ▸ Assistant ▸ Use Language Models and Agents** is one switch over
everything: the `⌘K` line, the bar over a selection, the agent panel, deep
research, and six's MCP server.

Off is not a greyed-out button. The line is not there at all, `⌘K` and `⌘⇧A` are
disabled in the menu, the watcher that follows the selection is **removed from
the pages** (a page opened after that gets nothing of six's in it), and the
socket external agents drive the browser through is closed.

Bookmark search and page translation keep working: neither is a model talking to
you — one is search, the other is a translator.

You are asked once, on the first launch, in a window on the rail —
`six://welcome`. The answer is never final: the switch is always there.

## Which model answers

| | |
|---|---|
| **On-Device** | the system's model; nothing leaves the Mac |
| **Private Cloud Compute** | Apple's cloud, with its guarantees |
| **Claude Sonnet 5 / Opus 5** | with an Anthropic API key |
| **OpenAI-compatible** | anything speaking the `/chat/completions` format: OpenAI, a gateway, or llama.cpp and Ollama on this very machine |
| **Claude Code (ACP)**, **Codex (ACP)** | the same line answered by an [agent](/en/agents) — the same session and transcript as the `⌘⇧A` panel |

**OpenAI-compatible** is one menu entry rather than a list of models because what
it points at is a setting: `six://settings` ▸ **Assistant** holds an endpoint, a
model name and a key. A local server wants no key at all, and an empty field
means no authorization header is sent. The Anthropic key goes in the same place.

The verbs are answered by whatever answers the `⌘K` line, an agent included. One
chosen model answers everything the assistant is asked; an agent takes longer and
may ask permission, but the buttons over a selection always work.

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
