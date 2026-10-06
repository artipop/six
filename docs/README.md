# Savoia — documentation

Short, practical notes on how the app is put together. The [top-level README](../README.md) is the pitch; this is the
reference.

Everything on this page is written for whoever changes the code. What is written for whoever *uses* the browser is
[`guide/`](guide/) — the user guide, in Russian and English, published on the deffun site under `/docs/vi/`, an address kept from when the product was
called VI. It is a VitePress site whose root is that
folder, so nothing else in `docs/` can be published by accident:

```sh
cd docs/guide
npm ci
npm run dev      # http://localhost:5176/docs/vi/
npm run build    # into ../../../xciii/site/dist/docs/vi — the deffun site's own dist
```

The port is pinned, and the build writes into the site repository next door, which has to be checked out beside this
one. Normally it is built from there instead: `npm run build:all` in `xciii/site` does the landing and all three
guides in the order their output directories require.

A feature is not finished until `docs/guide/` says how to use it — in both languages, naming buttons with the strings
from [`Savoia/Localizable.xcstrings`](../Savoia/Localizable.xcstrings) rather than translating them by eye
([localization.md](localization.md)).

| | |
|---|---|
| [controls.md](controls.md) | every mouse control, and the keyboard in short |
| [hotkeys.md](hotkeys.md) | every key binding, grouped by where it works |
| [layout.md](layout.md) | tabs and groups: the model underneath, side by side, the ⌃Tab ring, groups by meaning |
| [start-page.md](start-page.md) | the start page, search and suggestions |
| [architecture.md](architecture.md) | modules and how state flows |
| [extensions.md](extensions.md) | browser extensions: installing from a file, a controller per profile, and the measured boundary of what a `WebPage` browser can host |
| [links.md](links.md) | links: the context menu Savoia had to take over, ⌘-click, and downloads without `WKDownload` |
| [sharing.md](sharing.md) | the Share menu both ways: the share button, and the extension that takes a page, text or a file from another app into a tab group or the bookmarks |
| [blocking.md](blocking.md) | ads and trackers: filter lists, `WKContentRuleList`, the shield and the per-site allowlist |
| [permissions.md](permissions.md) | site permissions: the camera and microphone per site, the page's own dialogs, and what a `WebPage` browser still cannot ask for |
| [certificates.md](certificates.md) | extra certificate authorities: the Минцифры CA Savoia ships switched off, what a switch actually does, and importing your own |
| [bookmarks.md](bookmarks.md) | bookmarks: readable Markdown copies per profile, on-device embeddings, search from the assistant and MCP |
| [assistant.md](assistant.md) | the assistant: verbs at a selection, at a caret and on the ⌘E line, over Foundation Models |
| [agents.md](agents.md) | the ACP client, agents on the ⌘E line, and the chat history (`savoia://chats`) |
| [devtools.md](devtools.md) | Web Inspector on Savoia's pages, and the console/network capture the agent tools read |
| [logging.md](logging.md) | what Savoia says happened: the unified log, the file under `~/Library/Logs`, and the levels |
| [mcp.md](mcp.md) | `Savoia --mcp`: the browser as an MCP server, and its tools |
| [webmcp.md](webmcp.md) | WebMCP: a page declaring tools of its own for agents — how Savoia carries them, the gate in front of them, and what is not built |
| [test-suites.md](test-suites.md) | external test suites Savoia can be run against — wpt where Savoia answers rather than WebKit, extensions, blocking, privacy, MCP, certificates — and the shared stand |
| [page-scripts.md](page-scripts.md) | every script Savoia runs or injects in a page, what a call costs (it is a user gesture), and what each is to become |
| [timers.md](timers.md) | every wait by the clock: which are what a timer is for, which stand in for an event and are worth replacing, and which stay |
| [tasks/](tasks/README.md) | work that is specified and not started, one file per task, in the order to take it |
| [accessibility.md](accessibility.md) | the accessibility overlay and `get_accessibility_tree`: WebKit's accessibility tree as the agent's eyes, read through `AXUIElement` by `Savoia --ax-read` — a second process, because Savoia asking itself deadlocks |
| [localization.md](localization.md) | the String Catalogs, English and Russian, and the line between what a person reads and what a model reads |
| [build.md](build.md) | toolchain, SDK override, sandbox |
| [deep-research.md](deep-research.md) | deep research: document tabs, the run, the writing tools, Save As, highlighted passages |
| [todo.md](todo.md) | what is planned and not built: geolocation and screen sharing, passkeys, CloudKit sync, SQLite + RAG, floating windows |
| [passkeys.md](passkeys.md) | plan: WebAuthn / passkeys and password autofill in a third-party WebKit browser |
| [speech.md](speech.md) | dictation into the agent panel and the ⌘E line, on the device: Parakeet and Silero on the Neural Engine, the self-test, and what is left |
| [storage.md](storage.md) | where data lives, and the core behind four protocol seams (diagram) |
| [sync.md](sync.md) | plan: CloudKit sync of history and other records; what CloudKit can carry (and vectors) |
| [webmcp.md](webmcp.md) | plan (in Russian): WebMCP — pages declaring tools for agents through `document.modelContext`, as Savoia's own polyfill since WebKit opposes it |
