# 14. Waits by the clock that have an event — one pass

[timers.md](../../timers.md) sorted every `Task.sleep` in the app by what it stands in for. Most are what a timer is
for and stay. Five wait a guessed number of milliseconds for something that has an event. This task replaces three
of them, in this order, and leaves two.

## 1. A load to end — the one with a race in it

Five copies of one loop: `waitForLoad` in `BrowserTools`, `BookmarkStore` and `Export`, `WebSearch.withLoading`,
`BookmarkStore.read`. Each sleeps 150 ms (300 in `read`) hoping `isLoading` has risen by then, and polls every
100 ms after. A load that starts later than the head start reads as already finished, and the tool reads the page
being left — an agent's `navigate` followed by `get_page_content` is exactly that case.

One helper that waits for the navigation to end (`page.navigations`, `.finished` or a failure), with the timeout
each caller already has as its ceiling. Mind that `BrowserTab` already has the one subscription to
`page.navigations` (`watchNavigations`), and the feed throws on a failed load — hang the wait on what `apply`
sees rather than opening a second subscription.

Reproduce the race before fixing it: a page that starts loading 300 ms after `navigate` returns, on the wpt stand.

## 2. A highlight to be painted

`HighlightStore.scroll(_:toHighlightMatching:)` sleeps 600 ms before scrolling, and `apply` sleeps 5.6 s before
asking what never anchored. The gesture-free call (`BrowserTab.callWithoutGesture`) is `callAsyncJavaScript` and
takes an `await`: let `HighlightScript.apply` return a promise that settles when its own five-second watch does.

## 3. Fullscreen to end

`BrowserTab.leaveElementFullscreen` polls `fullscreenState` up to 40 times, 50 ms apart, before a navigation is
allowed. The state is observable (`withObservationTracking`, as `PageElementFullscreen` already uses it).

## Left

- **The site icon's poll** — [02-site-icons.md](02-site-icons.md) takes the fetch out of the page altogether.
- **The translator following a feed** — cheap, backs off, stops by itself.
- Everything under "Left as they are, with the reason" in timers.md: focus and the keyboard, a page settling after
  an agent's action, WebKit's accessibility tree.

## What "replace" means

An event with a ceiling, not an event alone: the timeout stays as the bound, the poll and the guessed head start
go. Each of the three is its own commit, and timers.md loses the row.
