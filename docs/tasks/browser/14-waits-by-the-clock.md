# 14. Waits by the clock that have an event — one pass

[timers.md](../../timers.md) sorted every `Task.sleep` in the app by what it stands in for. Most are what a timer is
for and stay. Five wait a guessed number of milliseconds for something that has an event. One is done and one is gone; this task
replaces the one that is left, and leaves two.

## 1. A load to end — done

`BrowserTab.loadSettled(timeout:)` and `loadAndSettle` for a page that is no tab's; [timers.md](../../timers.md)
has it. The race was not reproduced on the wpt stand first: the five loops went in one commit ahead of
the move of every tab to a `WKWebView`, which rewrote the feed they hung on.

## 2. A highlight to be painted

`HighlightStore.scroll(_:toHighlightMatching:)` sleeps 600 ms before scrolling, and `apply` sleeps 5.6 s before
asking what never anchored. The gesture-free call (`BrowserTab.callWithoutGesture`) is `callAsyncJavaScript` and
takes an `await`: let `HighlightScript.apply` return a promise that settles when its own five-second watch does.

## 3. Fullscreen to end — gone

`BrowserTab.leaveElementFullscreen` and its forty polls were removed with the workaround they belonged to: a tab's
own `WKWebView` comes back from fullscreen by itself when the page navigates.

## Left

- **The translator following a feed** — cheap, backs off, stops by itself.
- Everything under "Left as they are, with the reason" in timers.md: focus and the keyboard, a page settling after
  an agent's action, WebKit's accessibility tree.

## What "replace" means

An event with a ceiling, not an event alone: the timeout stays as the bound, the poll and the guessed head start
go. Each of the three is its own commit, and timers.md loses the row.
