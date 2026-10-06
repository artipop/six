# Waits by the clock

Every `Task.sleep` in the app outside the self-tests, read in October 2026 and sorted by what it stands in for. Most
are what a timer is for. A few wait a guessed number of milliseconds for something that has an event, and those are
the ones worth replacing.

Nothing here is changed yet. This is the list to work from.

## What a timer is for

Left alone:

- **Debounce** — the tab sorter's pass, search and personal suggestions, the autosave of the snapshot and of the
  highlights, the search fields of the bookmarks and of the MCP catalog.
- **Idle and periodic work** — unloading the local language model, the dictation model and an idle agent errand;
  the tab cleaner; the filter lists' six-hour refresh; the bookmarks' refresh tick and the pause between sites.
- **A ceiling on someone else's answer** — thirty seconds for an agent's session list or model list, a second for
  an MCP app's teardown, the accessibility reader's watchdog, a WebMCP call's timeout.
- **A thing shown for a while** — the "copied" mark on the address, the flight of a download to its button, the picture retaken one
  switch animation after a window comes to rest.

## Worth replacing, most useful first

| what | where | waits by the clock for | the event it has |
|---|---|---|---|
| a load to end | `waitForLoad` in `BrowserTools`, `BookmarkStore` and `Export`; `WebSearch.withLoading`; `BookmarkStore.read` | 150 ms (300 in `read`) for `isLoading` to rise, then a poll every 100 ms (200) | `page.navigations` — `.finished`, or the error it throws |
| a site icon | `SiteIcons.ask` | up to 20 polls, 150 ms apart, for the page to leave a data URL on `window` | the promise itself: the gesture-free call is `callAsyncJavaScript` and takes an `await` |
| a highlight to be painted | `HighlightStore.scroll(_:toHighlightMatching:)`, and the second question in `apply` | 600 ms before scrolling; 5.6 s before asking what never anchored | the answer of `HighlightScript.apply`, and a promise for the end of its five-second watch |
| fullscreen to end | `BrowserTab.leaveElementFullscreen`, before a navigation | up to 40 polls, 50 ms apart | `fullscreenState` is observable |
| a feed that keeps growing | `PageTranslator.follow` | a poll from 800 ms backing off to 5 s | the observer already in the page could resolve a promise |

**The first row is the only one with a race in it.** The opening 150 ms is a guess at when `isLoading` turns true;
a load that starts later than that reads as already finished, and the tool reads the page being left. It is also
five copies of one loop. One helper that waits for the navigation to end, with the timeout each caller already has
as its ceiling, replaces all five.

The second row may not need doing: [tasks/browser/02-site-icons.md](tasks/browser/02-site-icons.md) takes the
fetch out of the page altogether.

The last row is the least useful. The loop is cheap, it backs off, and it stops by itself after a minute of nothing.

## Left as they are, with the reason

- **Focus and the keyboard** — the second `claim` 150 ms after the first (`WebViewResponder.Handle`), the address
  field let go of 200 ms after a window opens (`ContentView`), the six tries 50 ms apart to put focus back in the
  ⌘E field and the 120 ms before a selection is restored (`AssistantBar`). These wait for SwiftUI to finish laying
  out, which has no event, and a mistake here is the keyboard going to the wrong place. Change one only for a bug
  that names it.
- **A page settling after an agent's action** — `PageActions.settle` and `wait(for:)`. "Has it stopped changing" is
  a poll by nature: two reads that agree, bounded because some pages never stop.
- **WebKit's accessibility tree** — the 400 ms retry in `AccessibilityOverlay` and the second before
  `DerivedToolsButton` assesses a page. WebKit builds the tree when first asked and says nothing when it is ready.
- **The web view a pane is about to find** — `BrowserTab.awaitWebView` and `WebViewResponder.awaitedWebView`. These
  are already the event; the second is only its ceiling.
- **One turn later** — the 50 ms in `BrowserState` before a window that turned into a download is closed. It only
  has to be outside the policy decision it was called from.

## What "replace" means here

An event with a ceiling, not an event alone. A page that never finishes loading, a pane that is never laid out and
a promise that never settles all exist, and every wait above is in front of a person or an agent's turn. The
timeout stays as the bound; what goes is the poll and the guessed head start.
