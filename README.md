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
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore (VM)
six/Vendor      ClaudeForFoundationModels sources (see note below)
```

## Notes / caveats

- **Toolchain.** The app is built against the macOS 27 SDK from the *Command Line Tools* beta
  (`/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`, build 26A5406c, FoundationModels 2.0.68 — the same
  revision the OS runtime ships), because the installed Xcode 27A5209h carries an older SDK whose Foundation Models
  *executor* ABI doesn't match the OS and crashes third-party `LanguageModel`s on launch. `SDKROOT` and a
  `-plugin-path` for `SwiftUIMacros` are set in the target's build settings; drop both once Xcode's own SDK matches the
  OS beta. `FoundationModelsCompatibility` still probes the ABI at launch and disables Claude with an explanation if
  the runtime ever diverges again.
- `ClaudeForFoundationModels` (`main`; tags predate the beta 5 API changes) is compiled straight into the app target
  from `six/Vendor/` — SwiftPM targets ignore the project's `SDKROOT` override and would build against Xcode's stale SDK.
- App Sandbox is off because the ACP layer spawns `npx`/`claude`/`codex` from the user's toolchain.
- Claude Code refuses to run nested inside another Claude Code session; the ACP layer strips `CLAUDECODE` from the
  agent environment. If your `claude` default model isn't available through the SDK, set "Model override" in the
  agent panel (exported as `ANTHROPIC_MODEL`).
- The Anthropic API key for the assistant is stored in `UserDefaults` for development only.
