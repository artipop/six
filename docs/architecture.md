# Architecture

SwiftUI, one window, `@Observable` state in the environment. Everything is `@MainActor` except the ACP/MCP transports.
The entry point is `SavoiaMain`, not the `App`: with `--mcp` the process never touches AppKit and runs
`MCPStdioBridge` instead (see [mcp](mcp.md)).

```
Savoia/Tiling       TilingLayout (tab groups and columns — a tab, or two side by side — focus and moves)
Savoia/Input       KeyBindings + KeyContext (the table and what has the keyboard — in SavoiaCore, tested against
                docs/hotkeys.md), KeyEvents (NSEvent → those values), KeyRouter (the one key monitor)
Savoia/Browser     Profile, BrowserTab (a `WKWebView` of its own) + PageDelegate, LivePageCache (the live-page budget), BrowserState, History, SitePermissions + PageDialogs (camera/microphone per site, the page's own dialogs), SearchEngine, SearchSuggestions, WebSearch
Savoia/Bookmarks   Bookmark (tables), ReadablePage (page → Markdown), Embedder + MLXEmbedder (multilingual-e5 over MLX), BookmarkStore (files, vec0 index, search)
Savoia/Views       ContentView, TabStripView (tab bar + toolbar), TabPageView (a tab's page), ConfigurationPageView (savoia://configuration/<pane>#<tab>), StartPage, AssistantBar, AgentPanel, HistoryView, BookmarksView
Savoia/Assistant   ModelChoice/AssistantSettings, AssistantStore (streaming), FoundationModelsCompatibility
Savoia/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore
Savoia/Tools       BrowserToolCatalog (the tools, over BrowserState), BrowserModelTool (Foundation Models adapter)
Savoia/Documents   TextDocument + DocumentStore (Markdown files behind document tabs), Markdown (→ HTML for the preview), Export (Save As, File menu)
Savoia/Highlights  Highlight (the selectors), HighlightStore (highlights.json, re-anchoring on load), HighlightScript (the page-side JS)
Savoia/Research    ResearchRun + ResearchPreset (the snapshot shape and the prompt), ResearchCoordinator (group + document + agent)
Savoia/MCP         MCPServer + MCPHost (the catalog over a Unix socket), MCPSocket, MCPStdioBridge (`Savoia --mcp`)
Savoia/Persistence AppStateSnapshot (the Codable shape), SnapshotStore (a versioned JSON file), StatePersistence (autosave)
Savoia/Data        AppDatabase (the SQLite file, migrations), ConfigurationStore (the settings table)
Savoia/*.xcstrings Localizable + InfoPlist String Catalogs (English source, Russian) — see [localization](localization.md)
```

## State

`BrowserState` owns the profiles and the flat list of `BrowserTab`s; `TilingLayout` owns where they sit. A tab's
`content` is `.web` or `.document(TextDocument)` — a document is a tab like any other, with a
web view of its own that renders the Markdown preview (and exports it); see [deep-research.md](deep-research.md). The
web view is not part of the tab's identity: it comes and goes with the live-page budget (below). A tab exists
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

Views never mutate `TilingLayout` directly; they call `BrowserState`. See [layout.md](layout.md) for the model.

A `Profile` is a name, a colour, a `WKWebsiteDataStore(forIdentifier:)` and an optional working directory for agents
(otherwise its scratchpad, `Profiles/<name>/Scratchpad` under Application Support). Switching profiles switches `layout.activeProfileID`, which swaps
every tab and group at once.

### Moving a tab to another profile

**Move to Profile** in the page's context menu (`move_window_to_profile` over MCP) is a **rebuild**, not a
re-filing. A page's data store is fixed when the page is built, so `BrowserState.moveTab(_:toProfile:)` takes the
window apart, builds one against the other profile's store and puts it in the old one's place, keeping its id — the
same thing `replaceWithApp` does for a restored app that starts running. Everything keyed by that id goes on
pointing at the same window: the column, the `⌃Tab` ring, a research run holding it as a source, its picture on
disk. Nothing is remembered for `⌘⇧T`, because nothing was closed.

What is handed over is `BrowserTab.Trail` — the two lists of addresses the window can walk, WebKit's session state and
the picture, which is everything a discard already keeps (`discard()` builds the same lists the same way). What is
deliberately *not* handed over is everything the old profile had given it: its cookies, its extension controller,
its content controller with the blocker's rules on it (`pageControllers.forget(id)`, so the new page is configured
with a fresh one), its captured console, and its highlights. That is the point of the move — the page comes back as
the other profile sees it.

Two things the move does that a close does not. The column leaves a profile that may not be the one on screen, so it
goes through `TilingLayout.removeColumn(tabID:from:)`; and that call asks nothing when it empties a named group,
because the question a closed tab puts up would arrive over the profile the tab went *to*. The focus follows the tab.

The one window that will not go is a document heading for a private profile. Its text is a file under `Documents/`,
watched and written a second after every keystroke, and a private profile is the one written down nowhere — so
`canMove(_:to:)` refuses rather than delete a person's file to keep that promise, and the menu item is disabled.

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

A tab's `WKWebView` is a web content process — a JavaScript heap, a render tree, timers, a compositor. A hundred tabs
cannot hold a hundred of them, so Savoia does what every browser does and calls by the same name: it **discards**
the pages it is unlikely to be asked for and builds them again from the address. Discarding is not closing; the tab
stays where it is with its title, its address, its back/forward list with each entry's scroll offset
(`interactionState`, [page-scripts.md](page-scripts.md#scroll-and-history-interactionstate)) and a picture of itself.

`LivePageCache` is the budget, one queue for the whole app — every profile, every group. Switch to another tab and
back and the one you just left is at the warm end of the queue with its page still on it.

- **Building waits for the focus to settle.** building the view is a web content process being attached —
  measured at 6–250 ms on the main actor, with the load after it — so doing it inside the click that moved the focus
  is a third of a second of stuck button, and walking the tabs with `⌘⇧]` would pay it at every tab passed. The build
  is scheduled one switch animation later (`LivePageCache.settleDelay`, 350 ms) and cancelled if the focus moves
  again. A tab that already has its page is shown at once, with nothing to wait for.
- **What is on screen is pinned and built.** `TilingLayout.visibleTabIDs` — the tab in front, and its partner when two
  are side by side — is never an eviction candidate. `BrowserState.refreshLivePages` follows the layout through
  `withObservationTracking`, so no view has to say anything.
- **The rest is LRU**, `budget` deep. The default is sized from the machine — about two pages per gigabyte of RAM,
  clamped to 16…64. Nothing sets it: it was a picker in the Layout menu, under a status line, and how many web
  content processes a Mac can carry is not a thing a person knows. `savoia://configuration` ▸ Tabs shows the number
  and offers no way to change it; `SAVOIA_LIVE_PAGES=n` pins it for measuring.
- **Guards**, the ones Chrome's Memory Saver uses: a page loading (for the last 20 s — plenty of pages never stop
  loading at all), playing audio or video, or holding a draft in a `textarea` or a filled-in password is skipped and
  the next candidate taken. Deliberately *not* "a field whose value differs from its attribute": that calls every
  search results page unsent input.
- **Memory pressure** takes a third off the budget on `.warning` — not half: on a small machine that band is the
  normal state rather than an emergency, and it never goes below what is on screen — and keeps only what is on
  screen on `.critical`. It grows back when the pressure lifts — and, because the system reports a transition and
  nothing guarantees the one that says "normal" ever arrives, a reported band expires after ninety seconds by itself.
  A browser that shrank on a warning it heard once and stayed shrunk for the rest of the launch is the bug you cannot
  see; if the pressure is real, growing back is what makes the system say so again.
- `SAVOIA_LIVE_PAGES=n` pins the budget and `SAVOIA_PAGE_CACHE_DEBUG=1` narrates evictions on stderr. Measured over 31 real
  pages, visiting every one: 22 web content processes and 798 MB with the budget out of the way, 6 and
  287 MB with it in place.

The ⌃Tab ring's cards are real pictures of the pages, taken with `WKWebView.takeSnapshot` — the same thing
Safari's tab overview and Chrome's tab switcher show. It is taken when a tab leaves the screen, when the ring opens,
and once for a tab that has never been drawn;
rate limited to one per window per three seconds, 400 pt wide, `afterScreenUpdates: false` so nothing is re-rendered
for it. Measured on the same pages: 4–100 ms each, 15 ms median, off the main actor. `LivePageCache.notePicture`
keeps the newest `budget × 4` (at least 24) in memory and the rest let go of theirs — a decoded bitmap per tab is
memory too, and giving memory back was the point.

The pictures themselves outlive both the page and the launch: `PageThumbnails` writes each one as a PNG under
`Application Support/org.deffun.savoia/Thumbnails/<window id>.png`, the way Firefox keeps `moz-page-thumbnails` and Safari keeps its
snapshots, because a ring of blank cards after a relaunch is exactly the moment they were for. They are read back
lazily — when the ring opens, for the tabs with nothing in memory — never all at once. `prune(keeping:)` drops the
pictures of tabs that no longer exist, at launch and as they close, so there is one file per open tab and no more.

Beside them, one file per **host**: `SiteIcons` keeps the site's own icon under
`Application Support/org.deffun.savoia/SiteIcons/<host>.icon`, which the tab bar draws, and what a card falls back to when there is no
picture of the page yet. WebKit fetches it, not Savoia and not a script: `SiteIcons` is the icon-loading delegate
(`_setIconLoadingDelegate:`, SPI behind `responds(to:)`) of every web view a pane finds, which is what Safari does.
After a load WebKit names the page's icons — each `<link rel="icon">` and `apple-touch-icon`, or `/favicon.ico` when
there is none — and asks about each; the three closest to 64 pixels are let through, the best that decodes is drawn
at 64 pixels and kept as a PNG, and a host that has its icon is not fetched again in that run. A `URLSession` asking
`https://host/favicon.ico` would be a second visit to that site from outside the profile it belongs to; these
requests leave in the page's own session, with its cookies. A private profile is given no `SiteIcons`, its views get
no delegate, and without one WebKit requests no icon at all — measured on a local server in each case.

It replaced a script in the page that fetched the icon and left a `data:` URL on `window`. On the thirty most
visited hosts of Artem's history, each opened at its root in a fresh profile, 23 had an icon with the script and 28
have one now: an icon on another origin needs no CORS, nothing depends on the page's `connect-src` or on `data:` in
its `img-src`, and there is no poll to run out. The two without (`sso.passport.yandex.ru`, `sso.kinopoisk.ru`) serve
a plain-text 404 and a one-byte `favicon.ico`. What still gets none:

- **a tab loaded in the background** (⌘-click, `open_window` with `activate: false`) — it has no web view to put the
  delegate on until a pane shows it, and WebKit does not ask twice. Accepted: the icon is per host and arrives with
  the next load of that host on screen;
- a page whose policy forbids the image itself (`img-src 'none'`): WebKit asks and hands back nothing;
- an icon a script adds or changes after the load: the delegate is not called for it.

On the tab side (`BrowserTab`): `page` builds the page on demand — everything that *talks* to a page goes through it
(tools, assistant, highlights, export) — while `title`, `currentURL`, `isLoading`, `canGoBack` and the rest answer
without one, because the tab bar is evaluated for every tab and reaching for `page` there would keep every tab live. `discard()` is synchronous on purpose: an `await` on the way out is something holding the page while
it waits. The picture is taken earlier, by `rememberViewState()`, while the page is still on screen and there is
still something to draw; the session state is read off the web view in `discard()` itself, which asks nobody.

Back and forward survive: the state is given to the rebuilt page's web view when a pane mounts it, and WebKit's own
list comes back with it. The window also keeps the URLs and walks them itself for a page rebuilt without a state. A window on the start page never builds a page at all — the start page is
SwiftUI.

## What Savoia says it is

`WKWebView`'s default user agent stops at the application name — `… AppleWebKit/605.1.15 (KHTML, like Gecko)
Savoia/1.0` — and contains no `Version/… Safari/…`. That token is what browser-sniffing scripts look for, so without it
they fall through to "unknown, probably ancient": Aviasales and Yandex both answer a fresh WebKit with *your browser
is out of date*.

`UserAgent` (`Savoia/Browser/UserAgent.swift`) sets `applicationNameForUserAgent` to Safari's own tail instead, so the
string Savoia sends is identical to the Safari installed on the machine — the version is read from
`/Applications/Safari.app` at launch (falling back to the macOS major version), so the claim ages with the system
rather than with this file. It is not a disguise: the engine, the JavaScript and the quirks really are that Safari's.
Naming ourselves in the same string is what broke it, so we don't.

`WKWebView.customUserAgent` can override the string per page, which is where per-site quirks would go if a site ever
needs a different answer. Nothing that is not in the user agent is faked: `navigator.userAgentData` stays absent (it
is Chromium's), and a site that insists on it will simply not recognise us.

## Being a browser

macOS decides what an app *is* from its `Info.plist`, and Xcode's generated one says "an app". `Info.plist` at the
repo root fills the gap and `GENERATE_INFOPLIST_FILE` stays on, so the generator's keys (bundle name, version,
`NSPrincipalClass`) are merged into it at build time. It sits at the root rather than in `Savoia/` because that folder
is a file-system-synchronized group: anything inside it is added to the target, and the plist would be copied into
`Resources` as well.

What it declares: `CFBundleURLTypes` for `http`/`https` as a Viewer — the key that puts Savoia in System Settings ›
Desktop & Dock › Default web browser — and for `file`; `CFBundleDocumentTypes` for HTML, web archives, `.webloc`,
PDF, images and text, all `Alternate` so Preview and TextEdit keep their files; `NSUserActivityTypes` for Handoff;
camera, microphone and location usage strings, without which a site's permission prompt has nothing to say and the
request is denied; and `NSAllowsArbitraryLoadsInWebContent`, which is for page content only, not for what Savoia fetches
itself. The app menu's **Set Savoia as Default Browser…** calls `NSWorkspace.setDefaultApplication` for both schemes;
macOS puts up its own confirmation, as it should — an app cannot promote itself silently.

The receiving end is the scene itself. `SavoiaApp.body` declares a `Window`, not a `WindowGroup`, and that is the whole
defence: SwiftUI answers an external open — a link from another app, a Handoff tile — by asking `AppWindowsController`
for a *window*, and a group happily builds a second one, which would show the same tabs twice — one web view
cannot be in two windows. A `Window` scene has nowhere to build, so SwiftUI raises the one that is up and
delivers to it. With that in place the sanctioned modifiers do the rest: `.onOpenURL` for links and files,
`.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` for Handoff from another device, and
`handlesExternalEvents(preferring:allowing:)` with `"*"` saying the one window takes everything.

Two things macOS does not do for us, both in `ExternalOpen.swift`. It leaves whatever app was clicked in front, so
`comeForward()` activates Savoia and digs the window out if it was minimised. And a `.webloc` is a plist wrapping a URL,
so `resolve(_:)` opens what it points at rather than the file.

## Persistence

Everything that makes up a session — the selected profile, every tab (URL, title and the trail it walked to get
there) and every profile's groups (workspaces with their names, their columns, focus), the downloads that did not
finish, plus the agent chats — is one `AppStateSnapshot`,
written to `~/Library/Application Support/org.deffun.savoia/state.json` — the folder is the bundle identifier, so a Debug
build writes to `org.deffun.savoia.dev/` and the two never meet (`AppSupport`, and
[build.md](build.md#two-apps-the-one-you-use-and-the-one-you-build)). The snapshot types, `SnapshotStore` and `StatePersistence`
use only Foundation and Observation (no SwiftData, no AppKit), so the format and the machinery are portable as they
are; only the mapping to the live objects (`BrowserState.snapshot` / `init(snapshot:)`, `TilingLayout.allStrips` /
`restore(strips:)`, `AgentSessionStore.snapshot` / `init(snapshot:)`) is app code.

Who the profiles *are* is not in that file. They are two tables in the database, behind `ProfileStore`,
because a profile is the identity `visits`, `bookmarks` and every cookie jar are already keyed by — and while it
lived only in the snapshot, one file that would not decode cost all of it: the app started with `Profile.defaults`,
minted fresh `WKWebsiteDataStore` identifiers, and the autosave wrote them over the only copy of the old ones a
second later. Every login in every profile, gone; the site data on disk orphaned rather than deleted. The snapshot
still *carries* the profiles, but it is never read back: an empty table is a new browser. Losing `state.json` now costs a session, which is what a session snapshot should
cost.
Two tables and not one because of the sync engine that is not written yet: `profiles(id, name, colorHex, ord)` is
who the profile is, under an id two Macs could agree on, and may one day be named to a `SyncEngine`;
`profile_storage(id, dataStoreID, workingDirectoryPath)` is where *this* Mac keeps that profile's things, and never
may be. A `SyncEngine` names tables and there is no filter below one, so a device-local column is safe only until
somebody opts its table in, while a device-local table is safe by being left off a list ([sync.md](sync.md)).
`ProfileStore` splits on the way in and joins on the way out, so nothing above it sees the seam — and a profile that
turns up with no storage beside it, the shape a synced one would have, is given a new data store on the spot:
cookies do not travel, so a profile met for the first time on a Mac is signed out.

`FileSnapshotStore` writes the file, flushes it and only then lets it take the name — `Data.write(.atomic)` renames
a temporary file into place but never flushes it, so a machine that goes down unclean could come back with the
rename and none of the bytes behind it. A file that will not decode is moved to `state.json.unreadable-<time>`
rather than left to be overwritten by the fresh one.

`StatePersistence` reads the snapshot under `withObservationTracking`, so any change to anything it touches — a
page's URL, a column moving, a chat line — schedules a debounced (1 s) write off the main thread; `NSApplication`'s
`willTerminate` flushes synchronously. On restore, a `BrowserTab` is created with its saved URL but doesn't load until
it first comes on screen (or a tool looks at it) — relaunching with a hundred tabs fires no requests.
That first load — and the one that rebuilds a discarded window — does not start media by itself: `MediaHold` puts a
script in Savoia's world that pauses any `play` until a trusted click or key press in that frame.
`mediaTypesRequiringUserActionForPlayback` does hold media on macOS — measured on an autoplaying audio element — but
a configuration is for the life of its view, so it holds every later navigation too; the script
is dropped as soon as the next navigation starts, so a reload or a link plays as usual.
The window itself — frame and fullscreen — is in the snapshot too (`WindowState`, fed by `NSWindow`
notifications and applied once when the content view lands in its window; a saved frame off every screen is
ignored). Restore drops anything that doesn't line up (a column whose tab is gone, a tab no column points at).

**Back and forward survive a relaunch, with the scroll offsets.** `TabSnapshot.state` is the tab's
`WKWebView.interactionState`, read as the snapshot is written and given to the tab's view when it loads again —
on screen or not ([page-scripts.md](page-scripts.md#scroll-and-history-interactionstate)). There is no list of
addresses beside it any more: a state over 512 KB is not written, and such a tab comes back at its address with no
history; `TabSnapshot.back` / `forward` remain in the format for a front whose engine has no session state. Only the
API key stays in `UserDefaults`; the other settings are in the database (below).

History and settings live in SQLite — `~/Library/Application Support/org.deffun.savoia/savoia.sqlite`, opened by `AppDatabase`
through [SQLiteData](https://github.com/pointfreeco/sqlite-data) (GRDB + StructuredQueries; `@Table` structs, typed
queries, `#sql` for the schema). Tables follow SQLiteData's CloudKit rules from the start — UUID text primary keys,
no `UNIQUE` elsewhere, columns only ever added — so turning its `SyncEngine` on later is configuration
([storage.md](storage.md), [sync.md](sync.md)). `profiles` and `profile_storage` are who the profiles are and where they are kept, above.
`visits(id, profileID, url, title, visitedAt)` is history:
each `BrowserTab` reports what its navigation delegate saw to `BrowserState`, which records the committed URL under the tab's
profile and fills in the title when the load finishes. `settings(key, value)` holds the preferences (search engine,
assistant model, groups by meaning, agent model override) behind the typed `ConfigurationStore`; the Anthropic API key stays in
`UserDefaults` — a credential has no business in a table that may sync. `HistoryStore` keeps a `revision` that every write
bumps, so a view reading through it under observation re-queries on change; searching and ranking run in Swift over
the profile's recent visits because SQLite's `LIKE`/`lower()` are ASCII-only. The **History** menu lists the selected profile's 20 most recent pages
(a click opens a new tab); ⌘Y opens `HistoryView` — the profile's whole history, searchable, by day.
There is no cap any more. Clearing asks whether to drop the profile's site data too (`BrowserState.clearSiteData`: every
`WKWebsiteDataStore` type — cookies, local storage, IndexedDB, caches — then the profile's open pages reload from origin). Removing a profile
removes its history.

Bookmarks are three more tables next to history — `bookmarks`, `bookmark_chunks`, `bookmark_vectors` — plus a
Markdown file per page in `Profiles/<name>/Bookmarks`; [bookmarks.md](bookmarks.md) has the pipeline, the embedder and the
search, and how sqlite-vec is loaded into the Apple SQLite.

## Page-side scripts

Everything Savoia runs inside a page — the readable-text extractor behind bookmarks and `get_page_content`, the link
lister, the highlight anchoring — goes through `WKWebView.savoia(_:arguments:)`
(`Savoia/Browser/PageScripts.swift`): `callAsyncJavaScript` in a `WKContentWorld` of Savoia's own. This is the arrangement
Firefox Reader View and Safari Reader use — the browser's script reads the page from a privileged context, never as a
guest of the page's own scripts. The DOM is shared, the JavaScript is not:

- the page cannot redefine `document.querySelectorAll`, the `innerText` getter or `getComputedStyle` to hand the
  extractor (and the model or agent reading its output) text a person never sees;
- the page cannot see Savoia's globals (the highlight registry's ranges, the constructed stylesheet) — nothing to
  detect, nothing to erase;
- what Savoia adds to the page is a constructed `CSSStyleSheet` in `document.adoptedStyleSheets` (a page's CSP has no say
  over it) and `Range`s in `CSS.highlights`, both DOM objects and both shared. `<mark>` wrappers and a `<style>` element
  exist only as fallbacks for engines without those APIs.

None of them watches a page. `PageFocusScript` reads the selection and the caret when ⌘E is pressed
([assistant.md](assistant.md)); it is also where password fields are dropped — in the page, before anything is sent —
and the same script is what writes an answer back into a field. Which scripts run by themselves, which are injected
ahead of time, and which carry a user gesture is in [page-scripts.md](page-scripts.md).

There are two deliberate exceptions. The `evaluate_javascript` tool runs in the page's world because that is what
it is for. The devtools capture ([devtools.md](devtools.md)) does too, and has to: `console.log` and `fetch` are the
page's own globals, so wrapping them anywhere else would wrap nothing. It is off by default, and what it returns is
described as the page's account of itself rather than the browser's. Its result is the page's word, not Savoia's. What isolation does not change: page text still reaches the
model — that is the task, not an injection — and the defence there is the agent's (permission prompts, treating page
content as data).

The scripts are function bodies, and `callAsyncJavaScript` runs them as an async function, so one may `await`. The
ones written when it could not still run fire-and-forget in the page — the highlight re-anchor watching a hydrating
page — and Swift asks for the outcome later.

## Views

`ContentView` is `TabbedWindowView` — the tab bar, the toolbar with the address field, and the page in front
(`TabPageView`, or two of them side by side) — with the assistant line overlaid at the bottom, the ⌃Tab ring over
everything, and the agent panel as an `.inspector`. When ⌘E is pressed over a caret or a selection the same line hangs
on the web view itself instead (`AnchoredAssistantLine`), as a `HostedOverlay` — SwiftUI drawn over a `WKWebView` never
sees the mouse. The window uses `.hiddenTitleBar`, and the tab bar keeps room for the traffic lights.

The page under the tab bar is drawn in one `ForEach` keyed by tab, so a tab joining or leaving a pair keeps its view.
`PageHost` is the one `NSViewRepresentable`: it puts the tab's own `WKWebView` in a plain view and holds it by frame;
a second host built over the same tab takes the view from the first. A tab with no live
page yet draws a placeholder with the site's icon and host until its page is built.

## From `WebPage` to `WKWebView`

Savoia was built on SwiftUI's `WebView` / `WebPage` and moved every tab to a `WKWebView` of its own in October 2026
(the `wkwebview` branch, task 23); this is the map the move was made by, kept for the next
sync of the `dev` branch. For that sync: `SavoiaCore` still knows no engine and the protocols a front implements kept
their shape; `TabSnapshot.back` / `forward` stay in the format and the Mac no longer writes or reads them; and the
iOS front there is still on `WebPage` — `PageDelegate` and `BrowserTab.materialize` are where the same move starts,
with `PageHost`, `PageContextMenu` and the dialogs being the AppKit parts.

What it cost in memory: nothing that can be told from noise. Ten tabs of a stand page in a throwaway home, all ten
live, the app and the twelve WebKit processes it started, twice each on 7 October 2026: a footprint of 1588 and
1816 MB on `WKWebView`, 1643 and 1546 MB on the build before the move. The third column is WebKitGTK's name for the same thing; **bold** there is what the Linux
front on `dev` already calls (`linux/Sources/SavoiaWebKit`, `SavoiaWebKitCore`, `SavoiaBrowser`). The rest of that
column was written from memory of its API and not compiled.

### Members

| `WebPage` | `WKWebView` | WebKitGTK |
|---|---|---|
| `WebPage(configuration:navigationDecider:dialogPresenter:)` | `WKWebView(frame:configuration:)`, `navigationDelegate`, `uiDelegate` | **`webkit_web_view_new`** and its construct properties |
| `WebPage.Configuration` — `websiteDataStore`, `userContentController`, `urlSchemeHandlers`, `applicationNameForUserAgent`, `webExtensionController` | `WKWebViewConfiguration`, the same fields; `setURLSchemeHandler(_:forURLScheme:)` | **`network-session`**, **`webkit_web_view_get_user_content_manager`**, `webkit_web_context_register_uri_scheme`, `webkit_settings_set_user_agent_with_application_details`, `web-extension-mode` |
| `url`, `title`, `isLoading`, `estimatedProgress` (observable) | the same properties under KVO, republished by `BrowserTab` | **`notify::uri`**, **`notify::title`**, **`webkit_web_view_is_loading`**, `notify::estimated-load-progress` |
| `load(URLRequest)`, `load(html:baseURL:)`, `reload(fromOrigin:)`, `stopLoading()` | `load(_:)`, `loadHTMLString(_:baseURL:)`, `reload()` / `reloadFromOrigin()`, `stopLoading()` | **`webkit_web_view_load_uri`**, `webkit_web_view_load_html`, **`webkit_web_view_reload`** / `_reload_bypass_cache`, `webkit_web_view_stop_loading` |
| `backForwardList`, `load(item)` | `backForwardList`, `go(to:)`, `canGoBack` / `canGoForward` | **`webkit_web_view_go_back`** / **`_go_forward`**, **`_can_go_back`** / **`_can_go_forward`**, `webkit_web_view_get_back_forward_list`, `_go_to_back_forward_list_item` |
| `navigations` (a throwing sequence) and `NavigationEvent` | `WKNavigationDelegate`: `didStartProvisionalNavigation`, `didCommit`, `didFinish`, `didFailProvisionalNavigation`, `didFail`, `webViewWebContentProcessDidTerminate` | **`load-changed`** (`STARTED`, `COMMITTED`, `FINISHED`), `load-failed`, `web-process-terminated` |
| `NavigationDeciding.decidePolicy(for: NavigationAction, preferences:)` | `webView(_:decidePolicyFor:preferences:)`; `targetFrame`, `navigationType`, `modifierFlags`, `shouldPerformDownload` | `decide-policy` with `NAVIGATION_ACTION` / `NEW_WINDOW_ACTION`, `webkit_navigation_action_get_modifiers` |
| `decidePolicy(for: NavigationResponse)` | `webView(_:decidePolicyFor: WKNavigationResponse)` | `decide-policy` with `RESPONSE`, `webkit_response_policy_decision_is_mime_type_supported` |
| `decideAuthenticationChallengeDisposition(for:)` | `webView(_:respondTo:)` | `load-failed-with-tls-errors`, `authenticate` |
| `WebPage.DialogPresenting` | `WKUIDelegate`: `runJavaScriptAlertPanel…`, `…ConfirmPanel…`, `…TextInputPanel…`, `runOpenPanelWith` | `script-dialog`, `run-file-chooser` |
| `Configuration.deviceSensorAuthorization` | `WKUIDelegate`: `requestMediaCapturePermissionFor`; the motion question has no delegate method on macOS and is gone | **`permission-request`** (**`WebKitUserMediaPermissionRequest`**) |
| `cameraCaptureState`, `microphoneCaptureState`, `setCameraCaptureState` | the same on `WKWebView` | `camera-capture-state`, `microphone-capture-state`, `display-capture-state` |
| `mediaPlaybackState()` | `requestMediaPlaybackState()` | `is-playing-audio` |
| `fullscreenState` | `fullscreenState` under KVO | `enter-fullscreen`, `leave-fullscreen` |
| `callJavaScript(_:arguments:contentWorld:)` | `callAsyncJavaScript(_:arguments:in:contentWorld:)` | **`webkit_web_view_call_async_javascript_function`** |
| `exported(as: .image(…))` | `takeSnapshot(with:)` | **`webkit_web_view_get_snapshot`** |
| `exported(as: .pdf())` | `pdf(configuration:)` | `webkit_print_operation_*` |
| `isInspectable` | `_inspector` with `developerExtrasEnabled` (SPI): the inspector opens in Savoia ([devtools.md](devtools.md#web-inspector)) | `webkit_settings_set_enable_developer_extras` |
| `WebView(page)` | one `NSViewRepresentable` handing out the tab's own view | the widget itself |
| `.webViewBackForwardNavigationGestures` | `allowsBackForwardNavigationGestures` | `webkit_settings_set_enable_back_forward_navigation_gestures` |
| `.webViewElementFullscreenBehavior` | `configuration.preferences.isElementFullscreenEnabled` | `webkit_settings_set_enable_fullscreen` |
| `.webViewContextMenu` | `_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:` (SPI), which is where the link under the pointer comes from; an `NSMenu` built by `PageContextMenu` | `context-menu` |

### Workarounds

| what `WebPage` forced | what became of it | WebKitGTK |
|---|---|---|
| `WebViewResponder`'s search of the view tree for a pane's `WKWebView`, and "only while on screen" | gone: `BrowserTab.livePage` is the view; the responder keeps the keyboard and nothing else | the widget is the page |
| `ScriptedPopups`: a proxy `WKUIDelegate` in front of `WebPage`'s own, and an `NSWindow` | gone: `PageDelegate` answers `createWebView` with a tab built on the configuration WebKit hands over, which keeps the opener | `create` |
| a `target=_blank` click cancelled in the decider and opened again by address | gone: it is the same `createWebView`; a ⌘-click is still cancelled and opened behind by address | `decide-policy` with `NEW_WINDOW_ACTION` |
| `interactionState` given to the view a pane mounts, a one-second wait for it, and address lists beside it | gone: the state is set as the tab resumes, on screen or not | `webkit_web_view_get_session_state`, `_restore_session_state` |
| `callWithoutGesture` falling back to the ordinary call off screen | gone; the ordinary call is left for the SPI being absent | the call there is not a gesture |
| `PageElementFullscreen`'s swap of the hold, `leaveElementFullscreen` before a navigation | both gone: `PageHost` holds the view by frame, and a navigation out of fullscreen puts the view back by itself | none |
| `MediaHold`, a user script | **stays**: `mediaTypesRequiringUserActionForPlayback` holds every later navigation in the view too | `webkit_settings_set_media_playback_requires_user_gesture` |
| picture-in-picture and screen sharing switched on as a pane claims a view | as the view is made | `display-capture-state` |
| extension pages in a window (`ExtensionStore.openExtensionPage`) | gone: a tab built on `WKWebExtensionContext.webViewConfiguration` | none |
| no automation of a tab | a mode of its own: tabs opened for remote automation carry the flag and a session, ordinary tabs never do ([devtools.md](devtools.md#remote-automation)) | `is-controlled-by-automation`, `WebKitAutomationSession` |
| no web archive | `createWebArchiveData`, in Save As | `webkit_web_view_save` (MHTML) |
| find reached through the pane's view | `find(_:configuration:)` on the tab's view | `webkit_web_view_get_find_controller` |
