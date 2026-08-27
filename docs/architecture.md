# Architecture

SwiftUI, one window, `@Observable` state in the environment. Everything is `@MainActor` except the ACP/MCP transports.
The entry point is `SixMain`, not the `App`: with `--mcp` the process never touches AppKit and runs
`MCPStdioBridge` instead (see [mcp](mcp.md)).

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), LivePageCache (the live-page budget), BrowserState, History, SitePermissions + PageDialogs (camera/microphone per site, the page's own dialogs), SearchEngine, SearchSuggestions, WebSearch
six/Bookmarks   Bookmark (tables), ReadablePage (page → Markdown), Embedder + MLXEmbedder (multilingual-e5 over MLX), BookmarkStore (files, vec0 index, search)
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, StartPage, AssistantBar, AgentPanel, HistoryView, BookmarksView
six/Assistant   ModelChoice/AssistantSettings, AssistantStore (streaming), FoundationModelsCompatibility
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore
six/Tools       BrowserToolCatalog (the tools, over BrowserState), BrowserModelTool (Foundation Models adapter)
six/Documents   TextDocument + DocumentStore (Markdown files behind document windows), Markdown (→ HTML for the preview), Export (Save As, File menu)
six/Highlights  Highlight (the selectors), HighlightStore (highlights.json, re-anchoring on load), HighlightScript (the page-side JS)
six/Research    ResearchRun + ResearchPreset (the snapshot shape and the prompt), ResearchCoordinator (workspace + document + agent)
six/MCP         MCPServer + MCPHost (the catalog over a Unix socket), MCPSocket, MCPStdioBridge (`six --mcp`)
six/Persistence AppStateSnapshot (the Codable shape), SnapshotStore (a versioned JSON file), StatePersistence (autosave)
six/Data        AppDatabase (the SQLite file, migrations), SettingsStore (the settings table)
six/Vendor      ClaudeForFoundationModels sources
six/*.xcstrings Localizable + InfoPlist String Catalogs (English source, Russian) — see [localization](localization.md)
```

## State

`BrowserState` owns the profiles and the flat list of `BrowserTab`s; `NiriLayout` owns where they sit. A tab's
`content` is `.web` or `.document(TextDocument)` — a document window is a column like any other, with a
`WebPage` of its own that renders the Markdown preview (and exports it); see [deep-research.md](deep-research.md). The
`WebPage` is not part of the tab's identity: it comes and goes with the live-page budget (below). A tab exists
because a column points at it — `newTab` appends a tab and inserts a column, `closeTab` removes both. **The focused
column is the selected tab**: `syncSelection()` copies `layout.focusedTabID` into `selectedTabID` after every layout
operation, and the assistant, the agent panel and `⌘L` all key off that.

Every window also has a `WKUserContentController` of its own, handed to its page as it is built and kept while the
window lives — that is what carries the compiled ad-blocking rules, and per *window* rather than per profile so the
per-site allowlist is a reload instead of a recompile. See [blocking.md](blocking.md). The page's
`webExtensionController` comes from the same moment, and is the profile's — see [extensions.md](extensions.md).
Both are fixed when the page is built, which is why anything that changes them goes through
`rebuildLivePages()`. So is the page's `deviceSensorAuthorization` — the closure that routes "may this site use the
camera?" to `SitePermissions` and suspends the page until the window's own bar is answered — and its
`dialogPresenter`, which is what makes `alert()` and `<input type="file">` work at all. See
[permissions.md](permissions.md).

Views never mutate `NiriLayout` directly; they call `BrowserState`, which wraps the call in the shared animation
(`animateLayout`). Strip panning is the exception — it follows the trackpad and is deliberately un-animated.

A `Profile` is a name, a colour, a `WKWebsiteDataStore(forIdentifier:)` and an optional working directory for agents
(otherwise its scratchpad, `Profiles/<name>/Scratchpad` under Application Support). Switching profiles switches `layout.activeProfileID`, which swaps
the whole workspace stack.

### Private browsing

Private browsing is a profile, not a mode: `⌘⇧P` (**File → New Private Window**, or `open_window` with
`private: true`) creates a profile with `isPrivate` set — one at a time, so its windows share a session the way
Safari's private windows do — and every later `⌘⇧P` adds a window to it. What makes it private is the data store:
`BrowserState.dataStore(for:)` hands a private profile `WKWebsiteDataStore.nonPersistent()` instead of
`WKWebsiteDataStore(forIdentifier:)`, so cookies, local storage, IndexedDB, caches and service workers live in memory
and go when the profile is dropped — the same WebKit API Safari's private windows use (`WebSearch` already runs its
off-screen page on one). Content worlds have nothing to do with it; they isolate JavaScript, not data.

What the app itself stops doing for a private profile: no history (`makeTab`'s navigation handler skips it), no
bookmarks (`BookmarkStore.add` refuses, the star and `⌘D` are disabled), no highlights (`HighlightStore` neither
applies nor stores; `highlight_page` refuses), no document files (`DocumentStore` neither watches nor saves — a
private document lives in memory), and no place in the snapshot: `BrowserState.snapshot` drops the profile, its
windows, its strip and its runs, so a relaunch starts without it. **Close Private Browsing** (File menu, or the
profile chip's context menu) closes the windows and forgets the profile; quitting does the same. The one file a
private profile can still touch is its agent scratchpad, if an agent is asked to work there.

## Live pages

A `WebPage` is a web content process — a JavaScript heap, a render tree, timers, a compositor. A strip of a hundred
windows cannot hold a hundred of them, so six does what every browser does and calls by the same name: it **discards**
the pages it is unlikely to be asked for and builds them again from the address. Discarding is not closing; the window
stays in the strip with its title, its address, its back/forward stacks, its scroll offset and a picture of itself.

`LivePageCache` is the budget, one queue for the whole app — every profile, every workspace. That is the point: step
out to another workspace and back and the windows you just left are at the warm end of the queue with their pages
still on them.

- **Building waits for the focus to settle.** `WebPage()` is a web content process being attached —
  measured at 6–250 ms on the main actor, with the load after it — so doing it inside the click that moved the focus
  is a third of a second of stuck button, and stepping along the strip would pay it at every window passed. The build
  is scheduled one switch animation later (`LivePageCache.settleDelay`, 350 ms) and cancelled if the focus moves
  again: hold ⌥→ across ten windows and exactly one page is built, the one you stopped at. A window that already has
  its page is shown at once, with nothing to wait for.
- **Pinning and building are different things.** `NiriLayout.visibleTabIDs` — the focused workspace's columns inside
  the viewport plus half a screen of margin — is *pinned*: never an eviction candidate, so the neighbours peeking in at
  the edges go on showing whatever pages they still have. Only the **focused** window is *built*. Walking down a
  restored strip loads one page, the one you stopped at, not one per window you passed; and if you were there recently
  it is still warm and there is nothing to load at all. `BrowserState.refreshLivePages` follows the layout through
  `withObservationTracking`, so no view has to say anything.
- **The overview builds nothing and mounts nothing.** The whole strip is on screen there, so everything is pinned and
  everything is a card — a live page in the overview is a page being laid out and composited at a fraction of its size
  for a picture of itself, a dozen times over, every time the view moves. The pictures are taken on the way in.
- **The rest is LRU**, `budget` deep. The default is sized from the machine — about one page per gigabyte of RAM,
  clamped to 8…32 — and the Layout menu has it (`Loaded Windows`), stored in the settings table.
- **Guards**, the ones Chrome's Memory Saver uses: a page loading (for the last 20 s — plenty of pages never stop
  loading at all), playing audio or video, or holding a draft in a `textarea` or a filled-in password is skipped and
  the next candidate taken. Deliberately *not* "a field whose value differs from its attribute": that calls every
  search results page unsent input.
- **Memory pressure** takes a third off the budget on `.warning` — not half: on a small machine that band is the
  normal state rather than an emergency, and it never goes below a workspace's worth — and keeps only what is on
  screen on `.critical`. It grows back when the pressure lifts — and, because the system reports a transition and
  nothing guarantees the one that says "normal" ever arrives, a reported band expires after ninety seconds by itself.
  A browser that shrank on a warning it heard once and stayed shrunk for the rest of the launch is the bug you cannot
  see; if the pressure is real, growing back is what makes the system say so again.
- `SIX_LIVE_PAGES=n` pins the budget and `SIX_PAGE_CACHE_DEBUG=1` narrates evictions on stderr. Measured over one real
  strip of 31 windows, visiting every one: 22 web content processes and 798 MB with the budget out of the way, 6 and
  287 MB with it in place.

The cards are real pictures of the pages, taken with `WebPage.exported(as: .image(…))` — the same thing Safari's tab
overview and Chrome's tab switcher show, and the only thing an app that isn't the compositor can show. It is taken
when a window leaves the screen, on the way into the overview, and once for a window that has never been drawn;
rate limited to one per window per three seconds, 400 pt wide, `afterScreenUpdates: false` so nothing is re-rendered
for it. Measured on the same strip: 4–100 ms each, 15 ms median, off the main actor. `LivePageCache.notePicture`
keeps the newest `budget × 4` (at least 24) in memory and the rest let go of theirs — a decoded bitmap per window is
memory too, and giving memory back was the point.

The pictures themselves outlive both the page and the launch: `PageThumbnails` writes each one as a PNG under
`Application Support/six/Thumbnails/<window id>.png`, the way Firefox keeps `moz-page-thumbnails` and Safari keeps its
snapshots, because an overview full of blank cards after a relaunch is exactly the moment they were for. They are read
back lazily — when the overview opens, for the windows with nothing in memory — never all at once. What bounds the
folder is the strip: `prune(keeping:)` drops the pictures of windows that no longer exist, at launch and as they
close, so there is one file per open window and no more.

On the tab side (`BrowserTab`): `page` builds the page on demand — everything that *talks* to a page goes through it
(tools, assistant, highlights, export) — while `title`, `currentURL`, `isLoading`, `canGoBack` and the rest answer
without one, because the title bar is drawn for every column in the strip and reaching for `page` there would keep the
whole strip live. `discard()` is synchronous on purpose: an `await` on the way out is something holding the page while
it waits. What the window needs afterwards is taken earlier, by `rememberViewState()`, while the page is still on
screen and there is still something to draw and someone to ask.

Back and forward survive: WebKit's own list goes with the page, so the window keeps the URLs and walks them itself
once a rebuilt page runs out of its own. A window on the start page never builds a page at all — the start page is
SwiftUI.

## What six says it is

`WKWebView`'s default user agent stops at the application name — `… AppleWebKit/605.1.15 (KHTML, like Gecko)
Six/1.0` — and contains no `Version/… Safari/…`. That token is what browser-sniffing scripts look for, so without it
they fall through to "unknown, probably ancient": Aviasales and Yandex both answer a fresh WebKit with *your browser
is out of date*.

`UserAgent` (`six/Browser/UserAgent.swift`) sets `applicationNameForUserAgent` to Safari's own tail instead, so the
string six sends is identical to the Safari installed on the machine — the version is read from
`/Applications/Safari.app` at launch (falling back to the macOS major version), so the claim ages with the system
rather than with this file. It is not a disguise: the engine, the JavaScript and the quirks really are that Safari's.
Naming ourselves in the same string is what broke it, so we don't.

`WebPage.customUserAgent` can override the string per page, which is where per-site quirks would go if a site ever
needs a different answer. Nothing that is not in the user agent is faked: `navigator.userAgentData` stays absent (it
is Chromium's), and a site that insists on it will simply not recognise us.

## Being a browser

macOS decides what an app *is* from its `Info.plist`, and Xcode's generated one says "an app". `Info.plist` at the
repo root fills the gap and `GENERATE_INFOPLIST_FILE` stays on, so the generator's keys (bundle name, version,
`NSPrincipalClass`) are merged into it at build time. It sits at the root rather than in `six/` because that folder
is a file-system-synchronized group: anything inside it is added to the target, and the plist would be copied into
`Resources` as well.

What it declares: `CFBundleURLTypes` for `http`/`https` as a Viewer — the key that puts six in System Settings ›
Desktop & Dock › Default web browser — and for `file`; `CFBundleDocumentTypes` for HTML, web archives, `.webloc`,
PDF, images and text, all `Alternate` so Preview and TextEdit keep their files; `NSUserActivityTypes` for Handoff;
camera, microphone and location usage strings, without which a site's permission prompt has nothing to say and the
request is denied; and `NSAllowsArbitraryLoadsInWebContent`, which is for page content only, not for what six fetches
itself. The app menu's **Set six as Default Browser…** calls `NSWorkspace.setDefaultApplication` for both schemes;
macOS puts up its own confirmation, as it should — an app cannot promote itself silently.

The receiving end is the scene itself. `sixApp.body` declares a `Window`, not a `WindowGroup`, and that is the whole
defence: SwiftUI answers an external open — a link from another app, a Handoff tile — by asking `AppWindowsController`
for a *window*, and a group happily builds a second one, which puts the same `WebPage`s into a second `WebView`;
WebKit traps and the process dies. A `Window` scene has nowhere to build, so SwiftUI raises the one that is up and
delivers to it. With that in place the sanctioned modifiers do the rest: `.onOpenURL` for links and files,
`.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` for Handoff from an iPhone, and
`handlesExternalEvents(preferring:allowing:)` with `"*"` saying the one window takes everything.

Two things macOS does not do for us, both in `ExternalOpen.swift`. It leaves whatever app was clicked in front, so
`comeForward()` activates six and digs the window out if it was minimised. And a `.webloc` is a plist wrapping a URL,
so `resolve(_:)` opens what it points at rather than the file.

## Persistence

Everything that makes up a session — profiles, the selected one, every tab (URL + title) and every profile's strip
(workspaces with their names, columns with their widths, focus) plus the agent chats — is one `AppStateSnapshot`,
written to `~/Library/Application Support/six/state.json`. The snapshot types, `SnapshotStore` and `StatePersistence`
use only Foundation and Observation (no SwiftData, no AppKit), so the format and the machinery are portable as they
are; only the mapping to the live objects (`BrowserState.snapshot` / `init(snapshot:)`, `NiriLayout.allStrips` /
`restore(strips:)`, `AgentSessionStore.snapshot` / `init(snapshot:)`) is app code.

`StatePersistence` reads the snapshot under `withObservationTracking`, so any change to anything it touches — a
page's URL, a column moving, a chat line — schedules a debounced (1 s) write off the main thread; `NSApplication`'s
`willTerminate` flushes synchronously. On restore, a `BrowserTab` is created with its saved URL but doesn't load until
it first comes on screen (or a tool looks at it) — relaunching with a hundred windows fires no requests.
The window itself — frame and fullscreen — is in the snapshot too (`WindowState`, fed by `NSWindow`
notifications and applied once when the content view lands in its window; a saved frame off every screen is
ignored). Restore drops anything that doesn't line up (a column whose tab is gone, a tab no column points at). Only the API key
stays in `UserDefaults`; the other settings are in the database (below).

History and settings live in SQLite — `~/Library/Application Support/six/six.sqlite`, opened by `AppDatabase`
through [SQLiteData](https://github.com/pointfreeco/sqlite-data) (GRDB + StructuredQueries; `@Table` structs, typed
queries, `#sql` for the schema). Tables follow SQLiteData's CloudKit rules from the start — UUID text primary keys,
no `UNIQUE` elsewhere, columns only ever added — so turning its `SyncEngine` on later is configuration
([storage.md](storage.md), [sync.md](sync.md)). `visits(id, profileID, url, title, visitedAt)` is history:
each `BrowserTab` feeds `WebPage.navigations` to `BrowserState`, which records the committed URL under the tab's
profile and fills in the title when the load finishes. `settings(key, value)` holds the preferences (search engine,
assistant model, `⌥C`, agent model override) behind the typed `SettingsStore`; the Anthropic API key stays in
`UserDefaults` — a credential has no business in a table that may sync. On first launch with the database the
old `history.json` and the `UserDefaults` keys are imported once. `HistoryStore` keeps a `revision` that every write
bumps, so a view reading through it under observation re-queries on change; searching and ranking run in Swift over
the profile's recent visits because SQLite's `LIKE`/`lower()` are ASCII-only. The **History** menu lists the selected profile's 20 most recent pages
(a click opens a new window in the strip); ⌘Y opens `HistoryView` — the profile's whole history, searchable, by day.
There is no cap any more. Clearing asks whether to drop the profile's site data too (`BrowserState.clearSiteData`: every
`WKWebsiteDataStore` type — cookies, local storage, IndexedDB, caches — then the profile's open pages reload from origin). Removing a profile
removes its history.

Bookmarks are three more tables next to history — `bookmarks`, `bookmark_chunks`, `bookmark_vectors` — plus a
Markdown file per page in `Profiles/<name>/Bookmarks`; [bookmarks.md](bookmarks.md) has the pipeline, the embedder and the
search, and how sqlite-vec is loaded into the Apple SQLite.

## Page-side scripts

Everything six runs inside a page — the readable-text extractor behind bookmarks and `get_page_content`, the link
lister, the scroll save/restore, the highlight anchoring — goes through `WebPage.six(_:arguments:)`
(`six/Browser/PageScripts.swift`): `callJavaScript` in a `WKContentWorld` of six's own. This is the arrangement
Firefox Reader View and Safari Reader use — the browser's script reads the page from a privileged context, never as a
guest of the page's own scripts. The DOM is shared, the JavaScript is not:

- the page cannot redefine `document.querySelectorAll`, the `innerText` getter or `getComputedStyle` to hand the
  extractor (and the model or agent reading its output) text a person never sees;
- the page cannot see six's globals (the highlight registry's ranges, the constructed stylesheet) — nothing to
  detect, nothing to erase;
- what six adds to the page is a constructed `CSSStyleSheet` in `document.adoptedStyleSheets` (a page's CSP has no say
  over it) and `Range`s in `CSS.highlights`, both DOM objects and both shared. `<mark>` wrappers and a `<style>` element
  exist only as fallbacks for engines without those APIs.

There are two deliberate exceptions. The `evaluate_javascript` tool runs in the page's world because that is what
it is for. The devtools capture ([devtools.md](devtools.md)) does too, and has to: `console.log` and `fetch` are the
page's own globals, so wrapping them anywhere else would wrap nothing. It is off by default, and what it returns is
described as the page's account of itself rather than the browser's. Its result is the page's word, not six's. What isolation does not change: page text still reaches the
model — that is the task, not an injection — and the defence there is the agent's (permission prompts, treating page
content as data).

The scripts are plain function bodies — `callJavaScript` runs a function, not an async one, so no `await`; anything
that has to wait (the highlight re-anchor watching a hydrating page) runs fire-and-forget in the page and Swift asks
for the outcome later.

## Views

`ContentView` is a top bar plus `NiriStripView`, with the assistant line overlaid at the bottom and the agent panel as
an `.inspector`. The window uses `.hiddenTitleBar` and the top bar reserves 68 pt for the traffic lights.

`NiriStripView` draws every workspace as a full-size layer offset vertically by `index - focusedIndex`, and every
column inside it at an absolute offset from `columnFrames`. That is why switching workspaces or scrolling the strip is
a single animated offset change rather than a view rebuild — the web views are never re-created.

A column only mounts a web view when it is near the screen *and* its window has a live page; otherwise it draws a card:
its title over the profile's colour in the strip, and the last picture of the page in the overview. Nowhere else — a
picture in the strip is only ever seen out of the corner of the eye, at the edge of the screen, in the moment before
the real page arrives, and a stale soft screenshot flashing where a page is about to be is worse than a card that never
pretended to be one. Off-screen workspaces mount nothing, mid-gesture included: a web view is a real AppKit view that
SwiftUI's clipping doesn't reach, and building one while a scroll is still deciding where to land is the worst moment
for the hitch it costs. They also answer no clicks at all (`allowsHitTesting`): a workspace laid out a screen above is
laid out over the top bar, and its cards and their shadows reach into it far enough to take a click off a button
there — which is how the overview button stopped working, intermittently, depending on the window's size. The top bar
sits in front of the strip (`zIndex`) for the same reason.
