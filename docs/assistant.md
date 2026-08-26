# Assistant (⌘K)

A Dia-style one-line input pinned to the bottom of the strip; the answer floats above it as a card.

Everything runs through Foundation Models' `LanguageModelSession`, so switching providers only swaps the model:

| | |
|---|---|
| On-Device | `SystemLanguageModel.default` |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` |
| Claude Sonnet 5 / Opus 5 | `ClaudeLanguageModel` from [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) |

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

`AssistantSettings` persists the model choice in `UserDefaults`. The Anthropic API key is read from the settings field
or `ANTHROPIC_API_KEY` and stored in `UserDefaults` — **development only**; a shipping app should use
`AuthMode.appAttest` or a proxy.

`FoundationModelsCompatibility` probes the executor ABI at launch and disables the Claude options with an explanation
if the runtime and the SDK diverge (see [build.md](build.md)). There is no official OpenAI provider for this protocol,
so GPT is not wired up.
