# six — documentation

Short, practical notes on how the app is put together. The [top-level README](../README.md) is the pitch; this is the
reference.

| | |
|---|---|
| [controls.md](controls.md) | every mouse control, and the keyboard in short |
| [hotkeys.md](hotkeys.md) | every key binding, grouped by where it works |
| [layout.md](layout.md) | the niri layout: model, geometry, gestures |
| [start-page.md](start-page.md) | the start page, search and suggestions |
| [architecture.md](architecture.md) | modules and how state flows |
| [platforms.md](platforms.md) | the macOS and iOS targets, and what differs |
| [extensions.md](extensions.md) | browser extensions: installing from a file, a controller per profile, and the measured boundary of what a `WebPage` browser can host |
| [links.md](links.md) | links: the context menu six had to take over, ⌘-click, and downloads without `WKDownload` |
| [blocking.md](blocking.md) | ads and trackers: filter lists, `WKContentRuleList`, the shield and the per-site allowlist |
| [permissions.md](permissions.md) | site permissions: the camera and microphone per site, the page's own dialogs, and what a `WebPage` browser still cannot ask for |
| [bookmarks.md](bookmarks.md) | bookmarks: readable Markdown copies per profile, on-device embeddings, search from the assistant and MCP |
| [assistant.md](assistant.md) | the ⌘K assistant on Foundation Models |
| [agents.md](agents.md) | the ACP client and the agent panel |
| [devtools.md](devtools.md) | Web Inspector on six's pages, and the console/network capture the agent tools read |
| [mcp.md](mcp.md) | `six --mcp`: the browser as an MCP server, and its tools |
| [localization.md](localization.md) | the String Catalogs, English and Russian, and the line between what a person reads and what a model reads |
| [build.md](build.md) | toolchain, SDK override, sandbox |
| [deep-research.md](deep-research.md) | deep research: document windows, the run, the writing tools, Save As, highlighted passages |
| [todo.md](todo.md) | what is planned and not built: geolocation and screen sharing, passkeys, CloudKit sync, SQLite + RAG, documents + Save As, fullscreen, PiP |
| [passkeys.md](passkeys.md) | plan: WebAuthn / passkeys and password autofill in a third-party WebKit browser |
| [storage.md](storage.md) | plan: where data lives, the portable core and the Apple/Linux adapters behind four protocol seams (diagram) |
| [sync.md](sync.md) | plan: CloudKit sync of history and other records; what CloudKit can carry (and vectors) |
