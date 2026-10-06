# TODO

What is planned but not built. Ordered by how much it is missed, not by effort.

## Two switches in the same corner mean two different sizes of thing

`savoia://configuration` has two panes that open with a switch, and the switch means something
different in each. Privacy puts **Block Ads and Trackers** in the pane's own header row, top right
beside the segmented picker (`ConfigurationPageView.PrivacyConfiguration`) — and it governs one of
the three segments, leaving Site Permissions and Certificates working. Assistant puts **Use Language
Models and Agents** in the first row of its Form (`AssistantPane`) — and it governs far more than
the pane: the ⌘E line, the agent path, the MCP server, the watcher `PageFocusStore` puts in every
page. So the switch that sits in the chrome, where it reads as the master of everything under it, is
the narrow one; the switch that sits in the list, where it reads as one setting among many, is the
broadest in the application.

Neither placement is wrong on its own, and the scopes are real — what is missing is a rule that
makes the difference visible before it is discovered. Options, none chosen: one place for a pane's
master switch and a sentence under it saying what it reaches; or the header row reserved for
switches that reach the whole pane, with the ad-blocking one moving down into Blocking's own list
where its scope is; or the broad one keeping its own shape, since turning off every model in the
browser is not the same kind of act as turning off a filter list.

Acceptance: a person who has used one of the two panes can predict, without trying it, how far the
other's switch reaches.

## Help inside the app

Savoia has no Help menu content and no help book: the only account of what a setting does is the
VitePress guide on the site. That used to be papered over by captions under almost every setting,
which made the configuration pages read like the guide and were cut down to the few that say
something a person cannot do without (a consequence, a missing step). What is owed is a Help menu
that opens the guide — the page for the pane in front of you, in the interface language — and a
`?` button on each configuration pane that goes to the same place. Offline is the open question: a
help book bundled with the app, or the guide's built pages shipped as resources and opened in a
window of Savoia's own.

## The ring's arrows are three keys

`⌃⇧←` / `⌃⇧→` walk the cards while the ring is held open. The `⇧` is a tax, not a design: macOS
owns plain `⌃←` and `⌃→` for Mission Control's *Move left/right a space* (symbolic hotkeys 79 and 80,
enabled by default), and the WindowServer takes them before any application's event monitor — so the
two keys a person would reach for cannot be had at all on a default Mac. The binding matches any
modifiers, so one extra key is enough to get the event delivered, and `⇧` is the one already under the
hand from `⌃⇧Tab`.

Three keys to page a carousel is a bad answer wherever it is written down, and
another one has not been found yet: the ring is held open *by* `⌃`, so every key it can answer is a
`⌃` chord, and the arrows are the only pair that says "the card over there" without being learned.

## Popups: what the window still lacks

A window opened with `window.open` has its opener now ([links.md](links.md#a-second-window)), as a `WKWebView` in a
window of its own. It has none of what a tab has: the page's dialogs, the permission bar, downloads, history. And
every script-opened window is one, including the many sites that call `window.open(url)` only to mean "a new
tab" — Safari gives those a tab that still has its opener, which a `WebPage` tab cannot be. Telling the two apart
by the size the page asked for (`WKWindowFeatures`) is the obvious next step, at the price of the unsized ones
losing their opener again.

## Save As: web archives

Document windows, Save As and highlights are built ([deep-research.md](deep-research.md)). What Save As still
lacks is `.webarchive` for pages: `WebPage` has no `createWebArchiveData` today, so a page saves as `.html` (its
source), `.pdf` or `.txt`. Downloads are built without `WKDownload` at all — see [links.md](links.md).

## Bookmarks: images

Today a bookmark keeps images only as `![alt](src)` in the Markdown and `og:image` in the front matter; nothing in
a picture is searchable. The plan, in the order it should be built ([bookmarks.md](bookmarks.md#embeddings) has what
the SDK offers and doesn't):

1. **OCR + labels, locally (Vision)** — the base. When a page is bookmarked, download its large images (≥ 120 px, at
   most ~20 per page) into `Bookmarks/<slug>/images/`, run `RecognizeTextRequest` (multilingual OCR) and
   `ClassifyImageRequest` (~1300 labels) on each, and store the result as chunks of a new kind —
   `bookmark_chunks(kind: image, imageURL, text)` — embedded like any text. Screenshots, diagrams, infographics,
   menus, tables-as-pictures become findable by their words; a photo by its labels. Don't lean on `alt` or
   `<figcaption>` — they are usually empty or wrong; use them only as extra words when present.
2. **Descriptions from Foundation Models** (macOS 27: the on-device model takes `Attachment<ImageAttachmentContent>`
   — `CGImage`, `CIImage`, `CVPixelBuffer`, `imageURL:`; nothing else, no PDF). Ask for a one-line description per
   image, in the user's language, and store it as another image chunk. Seconds per image, needs Apple Intelligence
   assets — a budget of ~10 images per page, in the background after step 1. Decide after seeing step 1 on real pages.
3. **A multimodal embedder** (Voyage `voyage-multimodal-3`, Cohere Embed v4) as a second `Embedder` conformer:
   image chunks embedded as images, text as text, one space — real text→image search and cross-lingual text at the
   same time. Remote, keyed, images leave the Mac; a setting, off by default.

PDFs: the model doesn't take them; `PDFPage.string` for the text layer and page renders as images through step 1/2
when `ReadablePage` learns to read a PDF `WebPage`.

## Extensions: the tab a content script cannot see

Hosting is built ([extensions.md](extensions.md)): install from a folder or an archive, a controller per profile,
actions in the top bar, permission prompts, and a compatibility verdict shown before anything runs. The one gap
behind it — `WKWebExtensionTab.webView(for:)` needed the live `WKWebView` and `WebPage` hands its own out to
nobody — now answers on macOS, through `WebViewResponder`'s existing per-tab lookup (a view-tree walk for
`is WKWebView`, matched by frame containment — not reflection into `WebPage`'s own storage, which was tried,
works, and stays unused). What that closes — messaging between a content script and its extension,
`scripting.executeScript`/`insertCSS`, uBlock Origin Lite's per-tab logic — is confirmed at the API level
(`webView(for:)` now answers the right tab correctly) but **not yet re-measured end to end**: a fresh MV3 test
extension hit a content-script-injection snag unrelated to this method in the same session, so the "what works"
table in [extensions.md](extensions.md) still describes the state from before this fix. iOS has no view-tree walk
yet and still answers `nil`.

The move that would close it without a workaround is upstream: nothing on bugs.webkit.org mentions `WKWebExtension`
and `WebPage` together, so this wants a bug (and a Feedback) asking for the backing view — or for a way to associate
a `WebPage` with a tab — with the measurements from [extensions.md](extensions.md) as the case. `WebPage.isInspectable`
is the precedent: something that lives on `WKWebView`, lifted into the new API.

Smaller things that follow once the boundary moves (or that are worth doing anyway): a workspace per extension
window rather than one window per profile strip.

**Extension pages inside Savoia's own interface.** An extension's options page, its dashboard and the pages it opens
with `tabs.create` open today in a plain `NSWindow` of their own (`ExtensionStore.openExtensionPage`), because a
column is a `WebPage` and WebKit will not load an extension's page as a main frame into one
([extensions.md](extensions.md#extension-pages-get-a-window-not-a-column)). Try to fit them into the row anyway.
The options, cheapest first: a panel Savoia places and sizes over the focused column instead of a free-floating window
(still a `WKWebView` from `context.webViewConfiguration`); a column kind that hosts that `WKWebView` through
`NSViewRepresentable` — an exception to the `WebPage`-only rule, to be weighed against everything such a column would
not have (find, translation, highlights, DevTools capture, discarding); or, if `WebPage.Configuration` ever takes a
configuration or a `requiredWebExtensionBaseURL` ([api-watch.md](api-watch.md)), ordinary columns with nothing
special about them. The new-tab override is blocked on the same thing.

`commands` bound to real keys is no longer on this list — see [extensions.md](extensions.md#commands-an-extensions-own-shortcuts).

## Someday: Savoia's own WebKit build

Two separate walls in this document are the same wall — WebKit can do the thing, the macOS SDK does not expose it:

- `WKWebExtensionTab.webView(for:)` needs a tab's `WKWebView`, and `WebPage` keeps its own private — macOS now
  answers this through a view-tree walk instead of waiting on Apple, but the walk is still a workaround for a wall
  the SDK put there in the first place ([extensions.md](extensions.md));
- there is no public way to *open* Web Inspector on your own page — the whole word "Inspector" appears in exactly
  one public header, as `WKWebView.isInspectable` — so Savoia can only let Safari attach ([devtools.md](devtools.md)).

Neither is a WebKit limitation. WebKit's inspector frontend is in the open-source tree, and the GTK port hands it to
applications as ordinary public API (`webkit_web_view_get_inspector`, `webkit_web_inspector_show`). Orion has
in-window developer tools on macOS, which means either SPI or a build of its own; Playwright ships a patched WebKit
precisely to reach the inspector protocol.

So the escape hatch, if the walls ever start costing more than they are worth: **build WebKit ourselves and embed
it.** What it would buy, in the order it matters — the inspector in Savoia's own window, the inspector protocol behind
the MCP devtools tools (real network with headers and bodies, a DOM snapshot, interactions), and whatever
`WebPage` refuses to hand over, including the backing view an extension tab needs.

What it costs, so this is not written down as if it were free: hours of build time and tens of gigabytes per
revision; the WebContent XPC services to embed, sign and sandbox; the size of the app; and — the real price —
**security updates become ours**. System WebKit is patched with the OS; a private copy is patched when we get
around to it, on a browser that runs other people's JavaScript. Every macOS release is also a chance for the build
to break.

Before that, two cheaper things should be tried, in order: **file the bugs** (nothing on bugs.webkit.org mentions
`WKWebExtension` with `WebPage`, and the inspector ask is a request for parity with a port that already has it),
and watch whether Safari's own MCP server (Safari 27 / STP 247) turns out to be reachable by other apps — it is the
same capability from the other end.

## The assistant: what the three surfaces still owe

Built: the catalog of verbs, the bar at a selection, the caret in a field, and the one-answer ⌘E
line ([assistant.md](assistant.md)). What was deliberately left for later, in the order it is
missed:

1. **Ghost text in the field itself.** A rewrite arrives in the strip at the bottom of the window
   and goes into the page on Return; the thing to build is the answer shown *in place* — grey text
   after the caret, Tab to take it — which needs an overlay positioned on a caret rectangle that
   moves with every keystroke, inside a page whose scrolling Savoia does not own. The strip is the
   honest version until that is measured.
2. **A verb of your own.** The catalog is a Swift array; the row that would make it a setting — a
   title, a prompt, where it applies — is the smallest useful next feature, and the reason the type
   is shaped the way it is.
4. **The phone.** `PageFocus` compiles on iOS and nothing reads it there: the Phone layout has no
   assistant surface at all yet, and a selection bar is a different gesture on a touch screen —
   iOS puts its own menu over a selection.
5. **Any ACP agent, not two.** The welcome's provider step and `ModelChoice.agents` know exactly
   Claude Code and Codex (`ACPAgentDefinition.builtIn`). ACP is a protocol, and the right shape is
   an "ACP" block in Configuration ▸ Assistant where any ACP-speaking binary is added by path and
   arguments, then offered everywhere the two built-ins are — the welcome included. Every variant
   `ModelChoice` has should be reachable from the welcome as well, not only the four doors it opens
   now (Private Cloud Compute is the one left out).

## Dictation: saying it instead of typing it

Built on the Mac: a microphone beside the agent panel's composer and the ⌘E line, FluidAudio's Parakeet TDT v3 with
Silero in front of it on the Neural Engine. What is left — Apple's `SpeechAnalyzer` as the engine that downloads
nothing, a Settings section with the model's Delete, a key, the phone — is at the end of [speech.md](speech.md).

## Developer tools: the half Chrome's devtools MCP has and Savoia does not

Web Inspector and capture are built ([devtools.md](devtools.md)): console, network, screenshots, over MCP. What an
agent still cannot do is *act* on a page except through `evaluate_javascript`, and cannot measure it:

- **A snapshot with stable ids** — Chrome's `take_snapshot` returns the accessibility tree with a uid per node, and
  every interaction tool takes one. Savoia has `list_page_blocks` for reading; the same idea with uids, over the
  accessibility tree rather than paragraphs, is what `click`, `fill` and `hover` would address.
- **Interactions as tools** rather than hand-written JavaScript: click, type, hover, select, drag, upload, and
  `wait_for(text)`. All of it is expressible through the page world today, which is why it is not urgent — but a
  tool that returns "the button was not there" beats a script that throws.
- **Performance traces and emulation** (CPU/network throttling, a device viewport). WebKit exposes none of this to
  an app; it would need the Web Inspector protocol, which is not reachable from the app hosting the page. Worth
  saying so in the docs and stopping there.
- **Request bodies and headers**, and request interception. The page-world hooks see status and timing only; going
  further means either the inspector protocol or a `WKURLSchemeHandler`-shaped proxy, and neither is cheap.

## Geolocation and notifications: WebKit's C API, one header for both

Site permissions are built ([permissions.md](permissions.md)): the camera, the microphone and the motion sensors are
asked for per site, remembered per origin and profile, and takeable back, and screen sharing works through the picker
WebKit presents by itself ([permissions.md](permissions.md#screen-sharing-which-webkit-asks-for-by-itself)).
Geolocation and notifications are still missing, and missing the same way: WebKit asks the app for permission through
a delegate, then expects the app to *supply* the thing — a position, a banner — through C functions that
`WebKit.framework` exports and the SDK does not declare.

The direction chosen (Artem, 2026-09-15) is to declare them, in a bridging header copied from WebKit's open-source
`WKGeolocationManager.h`, `WKNotificationManager.h` and `WKNotificationProvider.h`. The alternative weighed was a
JavaScript stand-in for `Notification` installed at document start: public API only, but an imitation, and no answer
for service-worker notifications.

What the two share, built once:

- **The header.** Savoia has none today. The functions — `WKContextGetGeolocationManager`,
  `WKGeolocationManagerSetProvider`, `WKGeolocationManagerProviderDidChangePosition`, `WKGeolocationPositionCreate`;
  `WKContextGetNotificationManager`, `WKNotificationManagerSetProvider`, `WKNotificationManagerProviderDidShowNotification`,
  `…DidClickNotification`, `…DidCloseNotifications`, `WKNotificationCopyTitle`, `WKNotificationCopyBody`,
  `WKNotificationGetID` — are all in WebKit's exports on this macOS (`dyld_info -exports`). The provider structs are
  versioned (`WKGeolocationProviderV1`, `WKNotificationProviderV0`), and a layout that no longer matches is a crash
  rather than a compile error, so the header pins one version.
- **The `WKContextRef`.** Both managers hang off the process pool `WebPage` built: `configuration.processPool` of the
  `WKWebView` that `WebViewResponder` finds. How that object becomes a `WKContextRef` from Swift is the first unproven
  step.
- **The delegate proxy.** Both permission questions are `WKUIDelegate` methods, answered in front of `WebPage`'s own
  adapter by the forwarding proxy from `e64dd24`, with its two lessons: the selector built from its string, and the
  proxy retained somewhere, because `uiDelegate` is weak. Forwarding everything else was verified — `confirm()` and
  the microphone still reached the adapter.

**Geolocation.** The permission hook is public (`requestGeolocationPermissionFor:initiatedBy:`, macOS 27); the
provider is not. Savoia would run `CLLocationManager` itself — `NSLocationWhenInUseUsageDescription` is already in the
Info.plist — and hand WebKit positions. Without a provider "Allow" led to a page that waited forever
([permissions.md](permissions.md#what-a-webpage-browser-still-cannot-ask-for)). First step: a position arriving in a
page at all.

**Notifications.** Measured on 2026-09-15 in a throwaway app, not in Savoia:

- `Notification.requestPermission()` is refused inside WebCore, before anyone is asked, unless it runs in a user
  gesture and a secure context. A script run over `Savoia --mcp` is not a gesture, which is why an early check from Savoia
  read `denied` in 3 ms and proved nothing about the delegate.
- A non-persistent data store — what Savoia's private profiles use — is refused in `WebNotificationClient` before the
  delegate too (`sessionID().isEphemeral()`). Private profiles would stay without notifications, as in Safari.
- With a persistent store, made the way Savoia makes its other profiles, and a real click, the private delegate method
  `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` was called, answered yes, and the page got
  `granted`. `new Notification()` then reached the UI process (`showNotification called` in the log) and went no
  further: no provider, no banner, no `onshow`.
- `BuiltInNotificationsEnabled`, the feature flag that looks like WebKit showing them itself, sends both permission and
  display to `webpushd` through the network process: `requestPermission failed: no active connection to webpushd`,
  refused in 0 ms, with the data store's `webPushMachServiceName` set.

The provider would post through `UserNotifications` (a system prompt of its own, once for the app), report shows and
clicks back to WebKit, and answer `notificationPermissions` from `SitePermissions`. Service-worker notifications come
through the same provider marked persistent, but their clicks go to `WKWebsiteDataStore` SPI — later, not first.

**Web Push** is out of reach rather than undocumented: `webpushd` checks the private entitlement
`com.apple.private.webkit.webpush` before serving a client, and Apple does not hand it out.

Savoia is not sandboxed and not on the App Store, so undeclared API carries no review risk here — only the ordinary one,
that it changes in a macOS update.

## Blocking: cosmetic rules inside a frame

[Advanced blocking](blocking.md#the-advanced-rules-what-runs-inside-the-page) is main frame only, and the reason is
structural rather than lazy. A `WKUserScript`'s source is fixed when it is installed on the content controller,
which happens before the load starts; the rules that apply to a subframe are the ones for the *subframe's own*
address, and that is not known until the frame loads. Giving a third-party frame the top document's cosmetic rules
would hide things inside it for no reason, so it is given none. What blocks inside a frame today is the network
half, which is per-request and needs nobody's help — so what is missing is scriptlets and extended CSS in frames,
which is where a certain kind of ad iframe lives.

Three ways it could be closed, none of them free:

- **Ask, then apply.** Inject one small script into every frame (`forMainFrameOnly: false`) that posts its own URL
  to a `WKScriptMessageHandler`, and have Swift answer with that frame's rules. Cheap and correct for CSS — a frame's
  cosmetics can arrive a moment late and still work. Useless for **scriptlets**, which have to patch a global before
  the frame's own scripts run, and a round trip through the main actor is not before.
- **Ship the lookup to the page.** Inject the engine's answers for every domain the page might frame — which is the
  whole index — or the engine itself as JavaScript. AdGuard's own extension does the second, in a background script;
  Savoia would be paying 350 KB and a build of the index per frame.
- **A `WKURLSchemeHandler`-shaped proxy**, or the Web Inspector protocol, so the rules could be applied to a frame's
  document before it is parsed. Both are the [own-WebKit-build](#someday-savoias-own-webkit-build) conversation.

The first is the only cheap one and it buys the smaller half. Worth doing when a real page is found where the frames
are the problem; not worth guessing at before that.

## Picture-in-picture — the window half

Two different features deserve the name, and the first of them is now built.

**Video PiP** — WebKit's own, for `<video>` — is done: `⌥⇧P`, a View menu item, and the button in WebKit's own media
controls. `WebPage.Configuration` turned out to have no field to allow it in, so it is SPI on the terms above, and the
floating player survives its window being scrolled out of the row, turned into a placeholder card and left behind for
another profile. What it took, and what was measured, is in [layout.md](layout.md#picture-in-picture).

**Window PiP** is not. Any Savoia window as a small always-on-top panel: an `NSPanel` at `.floating` level hosting the
page, which leaves the strip while it floats and returns to its column when closed. This is a floating layer, and
the same mechanism would later serve a proper floating-window mode. Nothing about the video half helps here — that one
is not even a window WebKit owns: `PIPAgent` draws it in a process of its own, on a system layer, snapped to a corner
of the screen, and Savoia can neither parent it to the browser window nor place it
([layout.md](layout.md#picture-in-picture) has the measurements). Which is the argument for this half: a floating
window Savoia draws is one it can put under the top bar and carry with the browser, and those are the two things asked
for about the video player that could not be answered.

## Passkeys and passwords

Sign in with a passkey (or a saved password) on any site, through the system UI. WebAuthn inside a third-party
`WKWebView` is gated by Apple's browser entitlements, so this is as much a paperwork task as a coding one. The plan,
the fallbacks and what to verify first are in [passkeys.md](passkeys.md). **Next up.**

## Sync through CloudKit — history first

History on every Mac (and later everything else that is a plain record: profiles, highlights, documents). Private
database, `CKSyncEngine`, one record per visit — visits are immutable, so there is nothing to merge. Design, limits
and what CloudKit can and cannot carry (vectors included) in [sync.md](sync.md). The store is ready for it — see the sync
columns under Storage below.

## Storage: history pages and retrieval

SQLite is the system of record — chosen and built: SQLiteData over GRDB for `visits`, `settings`, bookmarks and
their chunks and vectors (`Savoia/Data/`, `Savoia/Bookmarks/`, [architecture.md](architecture.md#persistence),
[bookmarks.md](bookmarks.md)). The app-state snapshot stays JSON — one small document, not a table. What is left:

- **History pages through the same store.** Bookmarks are the first RAG slice; history is the second: `pages(url,
  fetchedAt, text)` + FTS5 for visited pages, chunks and vectors like bookmarks, retrieval over what was *read*, not
  only what was saved. Decide when a visit is worth its text (dwell time, scroll, explicit "remember this").
- **`Retrieval` as a protocol.** The sqlite-vec KNN lives inside `BookmarkStore.vectorSearch` — one function to
  swap. Lift it behind a seam before a second index appears ([storage.md](storage.md)).
- **A bigger embedder when small isn't enough.** ~~One line in `MLXEmbedder.configuration`~~ — done, as a setting:
  `EmbeddingModelChoice` offers `multilingual-e5-small` and `multilingual-e5-base`, recommended by the Mac's memory
  and overridable ([bookmarks.md](bookmarks.md)). What is still open is a third rung — `multilingual-e5-large` or
  `bge-m3`, at 2 GB and up — and whether the ladder should be one the user climbs at all rather than one Savoia climbs
  for them. An ANN index (USearch) only past ~100k chunks — `vec0` is brute force too, just in C.
- **Prototypes worth an afternoon**, both caches over SQLite, never systems of record:
  [Wax](https://github.com/christopherkarani/Wax) — one `.wax` file with FTS5 + Metal HNSW, hybrid search in one
  query, own embedder and an MCP server; Apple Silicon first, single writer, v0.2. VecturaKit — embed + index +
  BM25 hybrid in one Swift API over MLX; Apple-only, own files.
- **The vector index off the Mac.** ~~Out of scope for the Linux phase~~ — built for both: sqlite-vec is registered
  per process (`Vectors.register()`) before the first connection, `VectorIndex` holds the `vec0` table and the KNN for
  every front, and `BookmarkIndexer` writes the rows, the passages and the vectors. The embedder is the same E5, run
  by transformers.js in a `PageSandbox` (`WebEmbedder`). Measured on Windows; **Linux is written and unrun** — the
  container is on the Mac. Windows has the bookmark button and `⌃D` now, beside the address the way the Mac's is. A saved page
  is its whole text there too: `ReadablePage` is in `SavoiaCore` and runs through `PageScriptRunner`, so the star saves
  the row at once and replaces its title-only passage with the page's a moment later. The Markdown copy is written
  beside the row there as well (`BookmarkFile`). What is still owed is somewhere to *see* the library — Windows has no
  bookmarks window, and Linux's `BookmarksSheet` searches titles and addresses only — and the hourly refresh, which
  needs an off-screen page with the profile's cookies.
- **Linux build of the data layer.** ~~Verify early~~ — done, and it builds: GRDB, SQLiteData, sqlite-vec
  and the `@Table` macros all compile on Swift 6.3.3/aarch64, as do `AppDatabase`, `ConfigurationStore`, `History`
  and `Bookmark`. No fallback needed. What it costs is two pins: `swift-sharing` 2.10.0 and
  `combine-schedulers` 1.2.1 regressed on Linux, and `sqlite-data` 1.11.0 does not compile against
  `structured-queries` 0.38 on any platform. The package's `Package.resolved` is seeded from the app's,
  which answers all three — so `swift package update` is Linux-breaking. Measured in [storage.md](storage.md).
- `record_name` / `sync_state` columns for [sync](sync.md) when it comes; the schema already follows SQLiteData's
  CloudKit rules (UUID text keys with `ON CONFLICT REPLACE`, no other `UNIQUE`, no column drops, BLOBs in their own
  tables), so nothing migrates.

Rejected, so it isn't re-litigated: Core Data / SwiftData (Apple-only, no FTS or vectors), Realm (sync dropped, no
Linux Swift), LMDB/RocksDB (everything built on top), Couchbase Lite (its own sync), DuckDB (poor for many small
writes), libSQL / Turso (native vectors, but not the system `sqlite3`, young Swift SDK), ObjectBox (closed core, no
Linux), PGlite (WASM runtime, data unreachable from `Savoia --mcp`), Qdrant / Milvus / Weaviate / Chroma (server
clients, nothing embedded).

## Tab groups by meaning: a classifier instead of cosines

`TabSorter` measures e5 cosines and asks for a lead, which leaves a tab whose title says little where it is and keeps
Russian titles out of English topics. The other shape is a classifier asked the question outright —
"which of these groups is this tab about, or none" — which is what jev / laya-browser are (a 322M "System 1" that
answers multiple-choice questions over `/v1/systemone`, tried for page actions on `origin/agent-actions`,
docs/agent-actions.md there). The options would be the group names plus "none"; the fit to try is whether its
confidence is calibrated enough to replace `joins` and `tie`, and what 0.35–1.3 s per tab on MPS costs when tabs
arrive in bursts. The same question asked of a local instruct model is built (**Sort By ▸ Local Model**,
docs/layout.md): Gemma 4 E2B places tabs better than the embeddings but at 5.6 s and 3.6 GB a tab on 8 GB, and
never answered "between". An ACP agent names groups through its own errand sessions (`AgentErrands`), but does not
place tabs yet.

## WebMCP: the nine wpt tests left

165 of 174 of wpt's `webmcp/` pass (`scripts/webmcp-wpt.py`, the baseline beside it). The nine left, and what each
would take — none of it is a polyfill's to do ([webmcp.md](webmcp.md#not-built)):

- **An opened window (2).** Needs [Popups](#popups-a-window-the-page-can-script) above; once `window.open` returns a
  window, the polyfill in it is already there and the broker only has to know it belongs to another frame tree.
- **`document.domain` (4).** The draft refuses the API where `document.domain` is enabled, and WebKit has no
  origin-keyed agent clusters, so the rule read literally refuses everything. Waits for WebKit to ship
  `Origin-Agent-Cluster` by default, or for the draft to phrase the rule so it has meaning there.
- **`isTrusted` on `toolactivated` (1).** Only an event the engine dispatches is trusted. Native WebMCP in WebKit, or
  Savoia's own WebKit build ([Someday](#someday-savoias-own-webkit-build)).
- **An iframe's initial `about:blank` when the iframe has a `src` (1).** WebKit runs no user script there, and the
  page reaches the document before it navigates. The parent's polyfill could install one into a same-origin child it
  sees created; wpt's own comment says Chrome fails this one too, so it waits for the test to settle.
- **Styling by `:tool-form-active` (1).** WebKit's CSS parser drops a rule with a pseudo-class it does not know.
  Engine work again.

Re-run the suite when wpt moves (`--update`): the declarative section of the draft is still TODO, and its tests are
where the next changes will land.

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- A window whose address *is* a download re-downloads it on every launch. Nothing was committed in it, so the
  window comes back pointed at the attachment and asks for it again; `closeIfOnlyCarriedALink` only closes the
  window a link opened, not the one somebody typed the address into. Harmless until this session, easy to see now
  that an unfinished row survives a relaunch.
- Deep research without an agent: a native loop over the ⌘E model for machines with no Claude Code / Codex, and
  exporting a run as one HTML file with its sources inlined ([deep-research.md](deep-research.md)).
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- **The row that moves up, shown moving up — in the overview.** Taking the last window out of the row (⌥⇧↓, or a drag
  in the overview) empties it, and the rule removes it: the row below takes its place, so the window you just
  sent *down* ends up on the top row — which is right, and reads strangely. In the row itself rows are not
  visible as rows, so nothing there can show it; the overview draws the whole stack, and there the lower row could
  fly up into the gap instead of the rows being renumbered in one cut.
- **Closing a full-width window with the mouse.** The × on a card sits on the corner a page does not want
  (`ColumnCloseBadge`), which works because a tiled window has a gap beside it; filled (⌥W) there is no gap, the page
  runs edge to edge, and the badge is not drawn at all — so ⌘W and the context menu are the only ways out. Everything
  that could stand there covers something: the top bar has no room left beside the address field, and a badge over
  the page is chrome charged against every page. The overview has a × per card now, which is the one place a window
  can be closed with the mouse whatever its fill.
- Forget one site: drop a single host's cookies and storage (`WKWebsiteDataStore.fetchDataRecords` →
  `remove(ofTypes:for:)`). Clearing a whole profile is the only option today, and it takes every login with it.
- Per-site user-agent overrides through `WebPage.customUserAgent`, for sites that sniff wrongly even at Safari's
  string.
- **The one warning left in `scripts/dmg.sh`.** `appintentsmetadataprocessor: Metadata extraction skipped, no
  AppIntents.framework dependency found` comes from Xcode's own build phase, once per build; the app has no App
  Intents, so it is harmless. It goes away if Savoia gets any (Shortcuts actions for open-tab and search would be the
  natural ones), and not before.
