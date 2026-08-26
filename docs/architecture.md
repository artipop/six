# Architecture

SwiftUI, one window, `@Observable` state in the environment. Everything is `@MainActor` except the ACP/MCP transports.
The entry point is `SixMain`, not the `App`: with `--mcp` the process never touches AppKit and runs
`MCPStdioBridge` instead (see [mcp](mcp.md)).

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), BrowserState, History, SearchEngine, SearchSuggestions, WebSearch
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, StartPage, AssistantBar, AgentPanel, HistoryView
six/Assistant   ModelChoice/AssistantSettings, AssistantStore (streaming), FoundationModelsCompatibility
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore
six/Tools       BrowserToolCatalog (the tools, over BrowserState), BrowserModelTool (Foundation Models adapter)
six/MCP         MCPServer + MCPHost (the catalog over a Unix socket), MCPSocket, MCPStdioBridge (`six --mcp`)
six/Persistence AppStateSnapshot (the Codable shape), SnapshotStore (a versioned JSON file), StatePersistence (autosave)
six/Data        AppDatabase (the SQLite file, migrations), SettingsStore (the settings table)
six/Vendor      ClaudeForFoundationModels sources
```

## State

`BrowserState` owns the profiles and the flat list of `BrowserTab`s; `NiriLayout` owns where they sit. A tab exists
because a column points at it — `newTab` appends a tab and inserts a column, `closeTab` removes both. **The focused
column is the selected tab**: `syncSelection()` copies `layout.focusedTabID` into `selectedTabID` after every layout
operation, and the assistant, the agent panel and `⌘L` all key off that.

Views never mutate `NiriLayout` directly; they call `BrowserState`, which wraps the call in the shared animation
(`animateLayout`). Strip panning is the exception — it follows the trackpad and is deliberately un-animated.

A `Profile` is a name, a colour, a `WKWebsiteDataStore(forIdentifier:)` and an optional working directory for agents
(otherwise its own folder under Application Support). Switching profiles switches `layout.activeProfileID`, which swaps
the whole workspace stack.

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

## Views

`ContentView` is a top bar plus `NiriStripView`, with the assistant line overlaid at the bottom and the agent panel as
an `.inspector`. The window uses `.hiddenTitleBar` and the top bar reserves 68 pt for the traffic lights.

`NiriStripView` draws every workspace as a full-size layer offset vertically by `index - focusedIndex`, and every
column inside it at an absolute offset from `columnFrames`. That is why switching workspaces or scrolling the strip is
a single animated offset change rather than a view rebuild — the web views are never re-created.
