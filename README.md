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
4. **The browser as an MCP server** — the same binary run as `six --mcp` is a stdio MCP server relaying to the
   running app over a Unix socket. Every ACP session gets it in `mcpServers`, so agents can open windows into a
   named workspace, read and summarize pages, move and close windows — the same tool catalog the assistant uses.
   See [docs/mcp.md](docs/mcp.md).

Windows, workspaces, profiles and agent chats survive a relaunch: one JSON snapshot under Application Support, autosaved
on change, ACP sessions resumed with `session/load`. See [docs/architecture.md](docs/architecture.md#persistence).

A window is not a page it holds forever. A `WebPage` is a web content process, so a strip of a hundred windows keeps
only as many live as the machine can carry and *discards* the rest, the way Chrome's Memory Saver and Safari's
suspended tabs do — the window stays where it is, with its address, its history, its scroll offset and a picture of
itself, and builds the same page again when you come back to it. Coming back is the case it is tuned for: one queue for
the whole app, so stepping out to another workspace and back finds the pages still warm.
See [docs/architecture.md](docs/architecture.md#live-pages).

Ads and trackers are blocked out of the box, by WebKit itself: filter lists are converted to WebKit's content-blocker
JSON and compiled into `WKContentRuleList`s, so a blocked request never leaves the content process and nothing runs
inside the page. Every window has its own content controller, which is what makes the per-site allowlist — the shield
in the address field — a reload rather than a ten-second recompile. The **Privacy** menu has the switch (off means
off: nothing fetched, nothing compiled), the lists and the sites left alone.
See [docs/blocking.md](docs/blocking.md).

Browser extensions run too, on `WKWebExtension` — installed from a folder, a `.zip`, a `.crx` or an `.xpi`, one
controller per profile, never in a private window. There is one thing six cannot give them: a tab's `WKWebView`,
which `WebPage` does not hand out, so a content script runs but cannot message its extension. That boundary is
measured rather than guessed, and every install says what it costs *that* extension before it runs.
See [docs/extensions.md](docs/extensions.md).

six registers with macOS as a browser: it claims `http`/`https` and the usual web file types, so it can be picked in
System Settings › Desktop & Dock › Default web browser (or from **Set six as Default Browser…** in the six menu), and
links or `.html` files opened from other apps land as windows in the strip.
See [docs/architecture.md](docs/architecture.md#being-a-browser).

## The niri layout

There are no tabs and no sidebar. A page is a **column**: a full-height window with its own title bar (navigation +
address field), laid out left to right in an endlessly scrollable **strip**. A column defaults to almost the full
width — an ordinary browser window, centred, with the neighbours peeking in at both edges to be scrolled to. A strip is a **workspace**; workspaces are
stacked vertically and exactly one is on screen at a time. The bottom workspace is always empty — move a window into it
and a fresh empty one appears below (niri's dynamic workspaces); a workspace that runs out of windows disappears,
unless you gave it a name (double-click its plate in the overview).

A new window opens on six's own start page — one field for both queries and addresses, with completions from the
search engine, so the first thing a window does isn't a network request. See [docs/start-page.md](docs/start-page.md).

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
| `⌥R` / `⌥⇧R` | wider / narrower columns — one preset for every window (½, ⅔, peek, full) |
| `⌥F` | compact width — this window at the widest preset, and back |
| `⌥W` | full window: the page fills the window, the top bar stays |
| `⌥C` | centre the focused window (default) or scroll the strip as little as possible |
| `⌥⇧F`, `Esc` | fullscreen: the page edge to edge, and `⌥←` `⌥→` still walk the strip |
| `⌥O`, `Esc` | overview — zoomed out just enough to show the focused strip end to end, scrolling sideways runs along it; no modifier needed there, a click opens a window |
| `⌘T` / `⌘W` | new window in the strip, right of the focused one / close it |
| `⌘Y` | the profile's history — searchable; the History menu lists the last 20 pages |

Only columns near the viewport get a real `WebView`; the rest render as cards, so a long strip stays cheap.

Full reference: [docs/](docs/) — [controls](docs/controls.md), [hotkeys](docs/hotkeys.md), [layout](docs/layout.md),
[architecture](docs/architecture.md), [blocking](docs/blocking.md), [extensions](docs/extensions.md), [assistant](docs/assistant.md),
[agents](docs/agents.md), [MCP server](docs/mcp.md), [build](docs/build.md).

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (⌥+scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), BrowserState, SearchEngine + SearchSuggestions
six/Extensions  ExtensionStore (a controller per profile), ExtensionInstaller (+ the compatibility verdict), adapters
six/Blocking    ContentBlocker (compiles + attaches rules), FilterList/FilterListStore (the lists), RuleConversion
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, StartPage, AssistantBar, AgentPanel
six/Assistant   ModelChoice/AssistantSettings (model selection), AssistantStore (streaming), FM compatibility probe
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore (VM)
six/Tools       BrowserToolCatalog (the tools, over BrowserState), BrowserModelTool (Foundation Models adapter)
six/MCP         MCPServer + MCPHost (the catalog over a Unix socket), MCPSocket (listener), MCPStdioBridge (`six --mcp`)
six/Vendor      ClaudeForFoundationModels sources (see note below)
```

## Testing ACP

Adapters are plain npm packages. The agent panel checks the toolchain in your shell's environment (an interactive login `zsh`, so `.zshrc` counts):

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

In the app: ⌘⇧A → pick the agent → send a message (it works in the profile's scratchpad, `Profiles/<name>/Scratchpad`, unless you choose another). Tool calls, plans and permission
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
