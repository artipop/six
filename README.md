# six

A minimal Arc-style macOS browser used as a playground for three things:

1. **SwiftUI + WebKit on the macOS 26+ APIs** — `WebView` / `WebPage` (no `NSViewRepresentable`), with several profiles
   in one window. Each profile is an isolated `WKWebsiteDataStore(forIdentifier:)`. Sidebar: profile switcher + tabs.
   ⌘T / ⌘W / ⌘L.
2. **Foundation Models (macOS 27) as the single LLM API** — a Dia-style one-line assistant (⌘K) driven by
   `LanguageModelSession`, switchable between the on-device `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`
   and Claude (`ClaudeLanguageModel` from [anthropics/ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels),
   which conforms to the new `LanguageModel` protocol). Page text is sent as context. There is no official OpenAI
   provider for this protocol yet, so GPT is not wired up.
3. **ACP (Agent Client Protocol) in Swift** — `six/ACP/` is a self-contained client: JSON-RPC over stdio,
   `initialize` / `session/new` / `session/prompt` / `session/cancel` / `session/set_mode`, streaming `session/update`,
   `session/request_permission`, and `fs/read_text_file` / `fs/write_text_file` served from the app (restricted to the
   session cwd). Built-in agents: Claude Code (`npx @zed-industries/claude-code-acp`) and Codex
   (`npx @zed-industries/codex-acp`). ⌘⇧A opens the agent panel (inspector).

## Layout

```
six/Browser     Profile, BrowserTab (WebPage), BrowserState
six/Views       ContentView, SidebarView, AddressBar, AssistantBar, AgentPanel
six/Assistant   ModelChoice/AssistantSettings (model selection), AssistantStore (streaming), FM compatibility probe
six/ACP         JSONValue, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore (VM)
Packages/       vendored ClaudeForFoundationModels (see note below)
```

## Notes / caveats

- **SDK vs OS mismatch.** As of 2026-08-25 this machine runs macOS 27 beta 6 (26A5416b) while the installed Xcode is
  27A5209h. The Foundation Models *executor* ABI (`LanguageModelExecutorGenerationChannel`, `Transcript.CustomSegment`,
  metadata types) differs between that SDK and the OS runtime, so any third-party `LanguageModel` compiled with this
  SDK crashes on a missing symbol. The app weak-links FoundationModels and probes the ABI at launch
  (`FoundationModelsCompatibility`); Claude entries are disabled with an explanation until the toolchain matches.
  Install the Xcode whose SDK matches the OS beta, rebuild, and Claude becomes selectable.
- `Packages/ClaudeForFoundationModels` is tag 0.1.4 with two small patches for that SDK (sampling-mode case names,
  server-tool custom segments stripped). Swap back to the remote package once a release builds against your SDK.
- App Sandbox is off because the ACP layer spawns `npx`/`claude`/`codex` from the user's toolchain.
- Claude Code refuses to run nested inside another Claude Code session; the ACP layer strips `CLAUDECODE` from the
  agent environment. If your `claude` default model isn't available through the SDK, set "Model override" in the
  agent panel (exported as `ANTHROPIC_MODEL`).
- The Anthropic API key for the assistant is stored in `UserDefaults` for development only.
