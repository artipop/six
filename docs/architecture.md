# Architecture

SwiftUI, one window, `@Observable` state in the environment. Everything is `@MainActor` except the ACP transport.

```
six/Niri        NiriLayout (workspaces, columns, geometry, focus/move ops), NiriScrollMonitor (scroll gestures)
six/Browser     Profile, BrowserTab (WebPage), BrowserState, SearchEngine, SearchSuggestions
six/Views       ContentView (top bar), NiriStripView (strip + overview), WindowChrome, StartPage, AssistantBar, AgentPanel
six/Assistant   ModelChoice/AssistantSettings, AssistantStore (streaming), FoundationModelsCompatibility
six/ACP         ACPJSON, JSONRPCConnection, ACPTypes, ACPAgent (process), ACPClient (actor), AgentSessionStore
six/Vendor      ClaudeForFoundationModels sources
```

## State

`BrowserState` owns the profiles and the flat list of `BrowserTab`s; `NiriLayout` owns where they sit. A tab exists
because a column points at it — `newTab` appends a tab and inserts a column, `closeTab` removes both. **The focused
column is the selected tab**: `syncSelection()` copies `layout.focusedTabID` into `selectedTabID` after every layout
operation, and the assistant, the agent panel and `⌘L` all key off that.

Views never mutate `NiriLayout` directly; they call `BrowserState`, which wraps the call in the shared animation
(`animateLayout`). Strip panning is the exception — it follows the trackpad and is deliberately un-animated.

A `Profile` is a name, a colour and a `WKWebsiteDataStore(forIdentifier:)`; profiles persist to `UserDefaults`, tabs
and layout do not (yet). Switching profiles switches `layout.activeProfileID`, which swaps the whole workspace stack.

## Views

`ContentView` is a top bar plus `NiriStripView`, with the assistant line overlaid at the bottom and the agent panel as
an `.inspector`. The window uses `.hiddenTitleBar` and the top bar reserves 68 pt for the traffic lights.

`NiriStripView` draws every workspace as a full-size layer offset vertically by `index - focusedIndex`, and every
column inside it at an absolute offset from `columnFrames`. That is why switching workspaces or scrolling the strip is
a single animated offset change rather than a view rebuild — the web views are never re-created.
