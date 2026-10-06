# 1. Scroll position through `interactionState`

Replace Savoia's own scroll restoration with WebKit's session state.

## Why

`BrowserTab.rememberViewState` reads `window.scrollY` with a script, and `restoreScrollIfNeeded` calls
`window.scrollTo(0, offset)` once, on `.finished`. If content arrives later, or the person has already scrolled,
the page jumps or lands in the wrong place. Artem sees scroll bugs he cannot explain and suspects this.
`WKWebView.interactionState` is the back-forward list with each entry's scroll position and form state, restored
the way Safari restores a tab.

## What is known

- [page-scripts.md](../../page-scripts.md), the section on `interactionState`.
- `WebPage` does not hand the state out ([api-watch.md](../../api-watch.md)); `WKWebView` on this system has the
  property (seen in the runtime's method list).
- The tab's `WKWebView` comes from `WebViewResponder.shared.webView(for:)`, and only while the tab is on screen.
- Savoia keeps the back and forward lists itself, as addresses: `savedBack` / `savedForward`
  ([architecture.md](../../architecture.md)).

## First, before any code

Measure whether a `WebPage` survives its `WKWebView` being given an `interactionState` behind its back: do
`page.url`, `backForwardList` and `page.navigations` stay in agreement afterwards? If not, stop and say so — do not
work around it.

## Done when

- A tab discarded by `LivePageCache`, and a tab after a relaunch, come back at the same scroll position on a long
  page that loads lazily, with back and forward intact.
- Both scripts are gone, and the address lists if the state replaces them.
- The docs say what is kept and where.

Check through `Savoia --mcp` in a throwaway home.
