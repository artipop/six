# 22. Web Inspector in Savoia's own window

Open WebKit's inspector on a tab from Savoia, instead of leaving it to Safari's Develop menu.

## Why

The docs said there was no way to open Web Inspector on your own page, and once listed it as a reason to build
WebKit ourselves — which is ruled out ([devtools.md](../../devtools.md)). There
is no *public* way. There is SPI, and it works on a tab.

## Measured, 6 October 2026, in a throwaway app — not in Savoia

`WKWebView._inspector` is a `_WKInspector` with `show`, `attach`, `detach`, `close`, `showConsole`,
`showResources`, `togglePageProfiling`.

- **It does nothing until `developerExtrasEnabled` is set** on the view's `WKPreferences` (by key; `isInspectable`
  is a different switch, for inspection from outside). With it off, `show` returns and `isVisible` stays false.
- **On a bare `WKWebView`**: after `show`, `isConnected`, `isVisible` and `isFront` are true and the inspector has
  its own frontend view. `attach` docks it under the page — the page's view went from 500 to 101 points tall in a
  500-point window. `close` gives the page its full frame back.
- **On the view a `WebPage` owns**, found in SwiftUI's `WebView` by walking the hierarchy, with the preference set
  after the view existed: the same, step for step. The page's view stayed in its window with a superview
  throughout, came back to its full frame after `close`, and `WebPage.url` and `title` were intact.

Not measured: a tab in Savoia's own layout, where the pane has other things stacked over the page (the permission
bar, the find bar); what an attached inspector does to `WebViewResponder`'s frame matching, to the fullscreen hold,
to a tab that is discarded while inspected; whether the docked height can be chosen.

## What to build

1. `developerExtrasEnabled` on every tab's preferences when Develop is on (`DevToolsStore.isInspectable` is the
   existing switch), through `WebViewResponder.onWebViewFound`.
2. **Show Web Inspector** in the Develop menu and `⌥⌘I`, on the focused tab: `show`, then `attach` if the tab is
   wide enough — decide by a fraction of the window, not a constant. SPI behind `responds(to:)`.
3. The measurements listed as not made, each before the code that depends on it.

## Done when

`⌥⌘I` opens the inspector on the focused tab and closes it, the tab survives a discard and a navigation with it
open, [devtools.md](../../devtools.md) and the guide say so in both languages, and
[api-watch.md](../../api-watch.md) lists the SPI.

## What this does not give an agent

The inspector is a window for a person: nothing in `_WKInspector` sends a protocol message. Request bodies and
traces reach a person through it, and still not an agent. The other door that was tried is in
[15-agent-tools-to-chrome.md](../agents/15-agent-tools-to-chrome.md).
