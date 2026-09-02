# Assistant (⌘K)

A Dia-style one-line input pinned to the bottom of the strip; the answer floats above it as a card.

It is out of sight until asked for: a bar resting over the bottom of every page covers what the page puts there —
a video's controls, most obviously. `⌘K` brings it up, an answer keeps it up, and it goes again when both are done.
(Temporary shape: it used to step aside only when the layout hid the chrome, and now it always does. What it should be — a hover band, a setting — is open.)

Everything runs through Foundation Models' `LanguageModelSession`, so switching providers only swaps the model:

| | |
|---|---|
| On-Device | `SystemLanguageModel.default` |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` |
| Claude Sonnet 5 / Opus 5 | `ClaudeLanguageModel` from [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) |
| OpenAI-compatible | `ChatCompletionsLanguageModel` from Apple's [foundation-models-utilities](https://github.com/apple/foundation-models-utilities) |

The same line can also be answered by an ACP agent — the menu's second section lists **Claude Code (ACP)** and
**Codex (ACP)**. Those go through the shared `AgentSessionStore` (the one behind ⌘⇧A): same session, same transcript,
same profile folder as the working directory; permission requests show up inside the answer card, and the tool the
agent is using is named next to the model label. The page is attached as a resource link rather than pasted in, since
the agent can read it through the browser's MCP tools.

`AssistantStore.ask(_:about:)` builds the prompt from the focused tab — title, URL and the page text (`document.body.innerText`, first 6 000 characters) — and
streams the reply into the card; `cancel()` stops the stream, `resetConversation()` starts a new session.

## Tools

The language models get the browser tools too: `BrowserToolCatalog` (`six/Tools/`) describes each tool once, and
`BrowserModelTool` wraps it as a Foundation Models `Tool` (arguments as `GeneratedContent`, schema built with
`DynamicGenerationSchema`). The same catalog is what MCP serves to agents (see [mcp.md](mcp.md)); only
`summarize_page` is MCP-only, since the assistant is a model already. The bookmark tools ([bookmarks.md](bookmarks.md))
are in the same catalog; the model menu's **Bookmarks** picker sets whether they see this profile or all. Tool failures that are the model's fault (a
bad window id) come back as text so it can retry, rather than ending the turn.

## OpenAI-compatible

**OpenAI-compatible** is one menu entry rather than a list of models, because what it points at is a setting: the
**Model Providers…** sheet holds an endpoint, a model name, and a key. Anything speaking the OpenAI
`/chat/completions` wire format answers there — OpenAI itself, a gateway, or llama.cpp and Ollama on this machine,
which want no key at all, so an empty one sends no `Authorization` header rather than an empty one. `OPENAI_BASE_URL`,
`OPENAI_MODEL` and `OPENAI_API_KEY` name any of the three for a single run.

The provider is Apple's own `ChatCompletionsLanguageModel`, vendored into `six/Vendor/FoundationModelsUtilities/`
for the reason the Claude bridge is (see [build.md](build.md)); the notes beside it list what upstream does not do
yet. It is a `LanguageModel` like the others, so tools, streaming and the transcript are the framework's — a tool call
comes back over `tool_calls`, six runs it, and the result goes out as a `tool` message keyed by the call's id.

`AssistantSettings` persists the model choice in `UserDefaults`. The Anthropic API key is read from the settings field
or `ANTHROPIC_API_KEY` and stored in `UserDefaults` — **development only**; a shipping app should use
`AuthMode.appAttest` or a proxy. The OpenAI key is kept the same way; the endpoint and model name are not secrets and
live in the settings table.

`FoundationModelsCompatibility` probes the executor ABI at launch and disables both remote options with an
explanation if the runtime and the SDK diverge (see [build.md](build.md)).
