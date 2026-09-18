# The assistant

Six's assistant is not a chat. It is one line, `⌘E`, and it comes up where you
are already pointing: under selected text, beside the field your caret is in,
and at the bottom of the rail when nothing on the page is pointed at. It never
comes up by itself.

The only conversation with a history left in six is the [agent](/en/agents) panel
on `⌘⇧A`, where the transcript is the work.

## The ⌘E line

`⌘E` brings the line up, `Esc` or `⌘E` again sends it away. An answer keeps it
up.

Ask freely, in your own words. The line says what the question will be about —
the selection, this field, or the whole page.

At a field or a selection the ready-made actions are up already, beside the
line: `←` and `→` walk them, `⏎` runs the chosen one, and a click runs any of
them. Start typing and the row goes, with the letter already in the line — from
there you ask in your own words.

At the bottom there is no row, because nothing is pointed at yet. The actions
are behind `/` there: type `/`, keep typing to narrow the list (`/sum` leaves
**Summarize This Page**), and `⏎` runs the first.

`⏎` sends the question. `⏎` on an empty line applies the answer already there.

## When you select text

Select some text and press `⌘E` — the line stands under the selection with the
actions above it:

| | |
|---|---|
| **Explain** | what this says, in plain language — terms and abbreviations included |
| **Summarize** | the same, shorter: three sentences, or a list where the text is one |
| **What is this?** | for a name, a term or a title |
| **Check this claim** | what it rests on, and what would have to be true for it to be wrong |

If the selection is **inside something you can write in** — a comment box, a
message, an editor on the page — the actions that change text come first: **Fix
Spelling and Grammar**, **Rewrite**, **Make It Shorter**, **Translate to
English**. **Explain** and **What is this?** stay; Summarize and Check this claim
do not — they are for text you are reading, not for your own draft.

## When the caret is in a field

Nothing is sent anywhere while you type. Leave the caret in the field and press
`⌘E` — the line stands beside the field, with the actions next to it:

| | |
|---|---|
| **Continue Writing** | carry on from exactly where you stopped |
| **Draft a Reply** | the field is a reply to what is on the page; here is one |
| **Polish What Is Written** | spelling, grammar and punctuation across the whole field, in your words rather than its own |

`Esc` puts the caret back in the field.

**Password fields are not read at all** — no content, no caret, no event: the
page drops them before anything reaches six. The same goes for fields that look
like a one-time code or a card number.

## How an answer gets into the page

It never gets there by itself. **Insert** or **Replace** appears under the
answer, and `⏎` on an empty line does the same. The text lands in the field as
if it had been typed, so `⌘Z` takes it back.

## Turning all of it off

**Configuration ▸ Assistant ▸ Use Language Models and Agents** is one switch over
everything: the `⌘E` line, the agent panel, deep
research, and six's MCP server.

Off is not a greyed-out button. The line is not there at all, `⌘E` and `⌘⇧A` are
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
it points at is a setting: `six://configuration` ▸ **Assistant** holds an endpoint, a
model name and a key. A local server wants no key at all, and an empty field
means no authorization header is sent. The Anthropic key goes in the same place.

The verbs are answered by whatever answers the `⌘E` line, an agent included. One
chosen model answers everything the assistant is asked; an agent takes longer and
may ask permission, but the actions behind `/` always work.

::: warning About keys, honestly
Keys are kept in the application's settings. That is enough to work on your own
machine, but it is not a secret store.
:::

## What the assistant can do besides answer

It is given the browser's tools — the same ones the [agents](/en/agents) get: open
a window, navigate, read a page, summarize it, search the web, close or move a
window, search your bookmarks. So "find flights and open three sites side by
side" is not a metaphor; it is what happens.

Which bookmarks it looks in is set by **Bookmarks ▸ Search In**, or by
the same picker in the model menu: this profile only, or all of them.

## The research command

`research: …` or `/research …` on the `⌘E` line starts
[deep research](/en/research): a workspace of sources and a document the agent
writes into.

## When a model is unavailable

The line says so, with the reason. The remote models can be switched off if the
runtime and the build disagree about their versions; that is checked at launch so
the application does not fall over on the first question.
