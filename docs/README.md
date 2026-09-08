# six — documentation

Short, practical notes on how the app is put together. The [top-level README](../README.md) is the pitch; this is the
reference.

Everything on this page is written for whoever changes the code. What is written for whoever *uses* the browser is
[`guide/`](guide/) — the user guide, in Russian and English, published on the deffun site under `/docs/vi/` (where the
product is called **VI**, beside XCIII and XXVI; in the app it stays `six`). It is a VitePress site whose root is that
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
from [`six/Localizable.xcstrings`](../six/Localizable.xcstrings) rather than translating them by eye
([localization.md](localization.md)).

| | |
|---|---|
| [controls.md](controls.md) | every mouse control, and the keyboard in short |
| [hotkeys.md](hotkeys.md) | every key binding, grouped by where it works |
| [layout.md](layout.md) | the niri layout: model, geometry, gestures |
| [start-page.md](start-page.md) | the start page, search and suggestions |
| [architecture.md](architecture.md) | modules and how state flows |
| [platforms.md](platforms.md) | the macOS and iOS targets, and what differs |
| [linux.md](linux.md) | the Linux front on WebKitGTK: the module split, what is built, and what GTK does differently |
| [extensions.md](extensions.md) | browser extensions: installing from a file, a controller per profile, and the measured boundary of what a `WebPage` browser can host |
| [links.md](links.md) | links: the context menu six had to take over, ⌘-click, and downloads without `WKDownload` |
| [blocking.md](blocking.md) | ads and trackers: filter lists, `WKContentRuleList`, the shield and the per-site allowlist |
| [permissions.md](permissions.md) | site permissions: the camera and microphone per site, the page's own dialogs, what a `WebPage` browser still cannot ask for, and the same questions on Linux |
| [certificates.md](certificates.md) | extra certificate authorities: the Минцифры CA six ships switched off, what a switch actually does, and importing your own |
| [bookmarks.md](bookmarks.md) | bookmarks: readable Markdown copies per profile, on-device embeddings, search from the assistant and MCP |
| [assistant.md](assistant.md) | the assistant: verbs at a selection, at a caret and on the ⌘K line, over Foundation Models |
| [agents.md](agents.md) | the ACP client and the agent panel |
| [devtools.md](devtools.md) | Web Inspector on six's pages, and the console/network capture the agent tools read |
| [mcp.md](mcp.md) | `six --mcp`: the browser as an MCP server, and its tools |
| [localization.md](localization.md) | the String Catalogs, English and Russian, and the line between what a person reads and what a model reads |
| [android.md](android.md) | the fourth front end: Kotlin and Compose on the system WebView, what it shares with the Mac and what it deliberately does not |
| [build.md](build.md) | toolchain, SDK override, sandbox |
| [deep-research.md](deep-research.md) | deep research: document windows, the run, the writing tools, Save As, highlighted passages |
| [todo.md](todo.md) | what is planned and not built: geolocation and screen sharing, passkeys, CloudKit sync, SQLite + RAG, floating windows, and what the Linux front still owes |
| [passkeys.md](passkeys.md) | plan: WebAuthn / passkeys and password autofill in a third-party WebKit browser |
| [storage.md](storage.md) | plan: where data lives, the portable core and the Apple/Linux adapters behind four protocol seams (diagram) |
| [sync.md](sync.md) | plan: CloudKit sync of history and other records; what CloudKit can carry (and vectors) |
