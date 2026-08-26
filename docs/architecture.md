# Architecture

SwiftUI, one window, `@Observable` state in the environment. Everything is `@MainActor` except the ACP/MCP transports.
The entry point is `SixMain`, not the `App`: with `--mcp` the process never touches AppKit and runs
`MCPStdioBridge` instead (see [mcp](mcp.md)).

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), BrowserState, History, SearchEngine, SearchSuggestions
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, StartPage, AssistantBar, AgentPanel, HistoryView
six/Assistant   ModelChoice/AssistantSettings, AssistantStore (streaming), FoundationModelsCompatibility
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore
six/Tools       BrowserToolCatalog (the tools, over BrowserState), BrowserModelTool (Foundation Models adapter)
six/MCP         MCPServer + MCPHost (the catalog over a Unix socket), MCPSocket, MCPStdioBridge (`six --mcp`)
six/Persistence AppStateSnapshot (the Codable shape), SnapshotStore (a versioned JSON file), StatePersistence (autosave)
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
Restore drops anything that doesn't line up (a column whose tab is gone, a tab no column points at). Settings
(search engine, assistant model, API key, `⌥C`, agent model override) stay in `UserDefaults`.

History is its own file, `history.json` (`HistoryStore`, same store and autosave, generic over the snapshot type):
it is bigger, changes on every page and losing it is no tragedy. Each `BrowserTab` feeds `WebPage.navigations` to
`BrowserState`, which records the committed URL under the tab's profile and fills in the title when the load
finishes; the newest 5000 visits are kept. The **History** menu lists the selected profile's 20 most recent pages
(a click opens a new window in the strip); ⌘Y opens `HistoryView` — the profile's whole history, searchable, by day.
Clearing asks whether to drop the profile's site data too (`BrowserState.clearSiteData`: every
`WKWebsiteDataStore` type — cookies, local storage, IndexedDB, caches; open windows stay). Removing a profile
removes its history.

## Views

`ContentView` is a top bar plus `NiriStripView`, with the assistant line overlaid at the bottom and the agent panel as
an `.inspector`. The window uses `.hiddenTitleBar` and the top bar reserves 68 pt for the traffic lights.

`NiriStripView` draws every workspace as a full-size layer offset vertically by `index - focusedIndex`, and every
column inside it at an absolute offset from `columnFrames`. That is why switching workspaces or scrolling the strip is
a single animated offset change rather than a view rebuild — the web views are never re-created.
