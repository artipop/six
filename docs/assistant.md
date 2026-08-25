# Assistant (⌘K)

A Dia-style one-line input pinned to the bottom of the strip; the answer floats above it as a card.

Everything runs through Foundation Models' `LanguageModelSession`, so switching providers only swaps the model:

| | |
|---|---|
| On-Device | `SystemLanguageModel.default` |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` |
| Claude Sonnet 5 / Opus 5 | `ClaudeLanguageModel` from [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) |

`AssistantStore.ask(_:about:)` builds the prompt from the focused tab — title, URL and the page text (`document.body.innerText`, first 6 000 characters) — and
streams the reply into the card; `cancel()` stops the stream, `resetConversation()` starts a new session.

`AssistantSettings` persists the model choice in `UserDefaults`. The Anthropic API key is read from the settings field
or `ANTHROPIC_API_KEY` and stored in `UserDefaults` — **development only**; a shipping app should use
`AuthMode.appAttest` or a proxy.

`FoundationModelsCompatibility` probes the executor ABI at launch and disables the Claude options with an explanation
if the runtime and the SDK diverge (see [build.md](build.md)). There is no official OpenAI provider for this protocol,
so GPT is not wired up.
