# six

A minimal macOS browser with a [niri](https://github.com/YaLTeR/niri)-style scrollable-tiling layout, used as a
playground for three things:

1. **SwiftUI + WebKit on the macOS 26+ APIs** — `WebView` / `WebPage` (no `NSViewRepresentable`), with several profiles
   in one window. Each profile is an isolated `WKWebsiteDataStore(forIdentifier:)` and has its own strip of workspaces.
   ⌘T / ⌘W / ⌘L.
2. **Foundation Models (macOS 27) as the single LLM API** — a Dia-style one-line assistant (⌘K) driven by
   `LanguageModelSession`, switchable between the on-device `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`
   and Claude (`ClaudeLanguageModel` from [anthropics/ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels),
   which conforms to the new `LanguageModel` protocol). Page text is sent as context. There is no official OpenAI
   provider for this protocol yet, so GPT is not wired up.
3. **ACP (Agent Client Protocol) in Swift** — `six/ACP/` is a self-contained client: JSON-RPC over stdio,
   `initialize` / `session/new` / `session/prompt` / `session/cancel` / `session/set_mode`, streaming `session/update`,
   `session/request_permission`, and `fs/read_text_file` / `fs/write_text_file` served from the app (restricted to the
   session cwd). Built-in agents: Claude Code (`@agentclientprotocol/claude-agent-acp`) and Codex
   (`@agentclientprotocol/codex-acp`). ⌘⇧A opens the agent panel (inspector).

## The niri layout

There are no tabs and no sidebar. A page is a **column**: a full-height window with its own title bar (navigation +
address field), laid out left to right in an endlessly scrollable **strip**. A column defaults to almost the full
width — an ordinary browser window, centred, with the neighbours peeking in at both edges to be scrolled to. A strip is a **workspace**; workspaces are
stacked vertically and exactly one is on screen at a time. The bottom workspace is always empty — move a window into it
and a fresh empty one appears below (niri's dynamic workspaces); a workspace that runs out of windows disappears.

Nothing needs the keyboard: click a background window to pull it in, use the `‹` `›` buttons on the screen edges —
at the end of the strip the right one becomes a `+` that adds a window — the workspace stepper in the top bar, and a
right-click on a title bar or on the background for the rest. Scrolling over the
layout's own chrome (title bars, gaps, background) pans the strip and changes workspace too — over a page, scrolling
stays the page's.

`⌥` stands in for niri's `Mod`, and with it held the gestures work anywhere:

| | |
|---|---|
| `⌥` + vertical scroll | one workspace up/down per gesture — deltas build up a rubber-band preview, cross the threshold and the switch commits, and the rest of the gesture (trackpad momentum included) is swallowed so a flick never skips two |
| `⌥` + horizontal scroll | one column per gesture while centring is on, so the strip never rests half-way; free panning with `⌥C` off |
| `⌥` `←` `→` / `⌥⇧` `←` `→` | focus / move a column |
| `⌥` `↑` `↓` / `⌥⇧` `↑` `↓` | focus a workspace / move the focused column to it |
| `⌥R` / `⌥F` | cycle preset column widths (½, ⅔, peek, full) / maximize |
| `⌥C` | centre the focused window (default) or scroll the strip as little as possible |
| `⌥O`, `Esc` | overview — zoomed out just enough to show the focused strip end to end, scrolling sideways runs along it; no modifier needed there, a click opens a window |
| `⌘T` / `⌘W` | new window in the strip, right of the focused one / close it |

Only columns near the viewport get a real `WebView`; the rest render as cards, so a long strip stays cheap.

Full reference: [docs/](docs/) — [controls](docs/controls.md), [layout](docs/layout.md),
[architecture](docs/architecture.md), [assistant](docs/assistant.md), [agents](docs/agents.md), [build](docs/build.md).

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (⌥+scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), BrowserState
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, AssistantBar, AgentPanel
six/Assistant   ModelChoice/AssistantSettings (model selection), AssistantStore (streaming), FM compatibility probe
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore (VM)
six/Vendor      ClaudeForFoundationModels sources (see note below)
```

## Testing ACP

Adapters are plain npm packages. The agent panel checks the toolchain through your login shell:

- adapter binary on PATH (`claude-agent-acp` / `codex-acp`) → used directly;
- only `npm` available → **Install** button runs `npm install -g <adapter>`; until then the agent starts via `npx -y`;
- no Node.js at all → link to https://nodejs.org/en/download;
- the underlying CLI (`claude` / `codex`) must be installed and logged in — the panel warns if it's missing.

Manual check from a terminal (what the panel does under the hood):

```sh
npm install -g @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp
claude-agent-acp   # then paste, one line each:
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true}}}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"<id from above>","prompt":[{"type":"text","text":"hi"}]}}
```

In the app: ⌘⇧A → pick the agent → choose a working directory → send a message. Tool calls, plans and permission
requests show up in the transcript; permission buttons answer `session/request_permission`.

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
