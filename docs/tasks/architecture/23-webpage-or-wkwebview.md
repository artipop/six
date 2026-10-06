# 23. `WebPage`, or a `WKWebView` of our own

Decide, by building enough to know, whether a tab stays a SwiftUI `WebPage` or becomes a `WKWebView` Savoia makes
itself. Not a rewrite: an inventory, a seam, and a second implementation behind a switch that Artem lives on for a
week.

## Why now

Savoia was built on `WebView`/`WebPage` on purpose (AGENTS.md, first paragraph). A year in, almost everything added
begins with "`WebPage` has no way to…, so take the view": nine files reach the `WKWebView` behind a `WebPage`
through `WebViewResponder`, a walk of the view tree that only finds a view while its tab is on screen. Savoia pays
for both models — it lives by `WebPage`'s rules and works through a `WKWebView` it does not own. The code that
knows `WebPage` is small: 44 files, 122 lines, nearly all of it in `BrowserTab`.

## The walls, each one measured

| what | on `WebPage` today | with a view of our own |
|---|---|---|
| `window.open` | a separate `NSWindow`; a `WebPage` cannot be the view WebKit asks for ([links.md](../../links.md#a-second-window)) | an ordinary tab with its opener, as in Safari |
| WebKit's automation, for an agent's tools | answers in-process, but lists no page for a `WebPage`'s view ([15](../agents/15-agent-tools-to-chrome.md)) | works — measured on a view made controlled by automation |
| extension pages, an extension's new-tab page | a window of their own ([extensions.md](../../extensions.md)) | tabs, from `WKWebExtensionContext.webViewConfiguration` |
| session state: scroll and history | only once a pane has shown the tab; address lists otherwise ([page-scripts.md](../../page-scripts.md)) | before the tab is shown; the address lists go |
| a script with no user gesture | a page off screen gets the ordinary call, which is a gesture | always |
| geolocation, notifications, popups | a delegate placed in front of `WebPage`'s own, forwarding the rest | our own delegate |
| element fullscreen | black without a temporary hold; a tab left blank by navigating out of it, worked around | as `WKWebView` does it — the hold exists because of how SwiftUI's `WebView` holds the view |
| Web Inspector | opens through SPI either way ([22](../devtools/22-web-inspector-in-savoia.md)) | the same |

What a view of our own does **not** change: Apple Pay (cause unknown), Web Push, the inspector's protocol for an
agent, the C API behind geolocation and notification providers.

## What Apple is doing with `WebPage`, read on 6 October 2026

There is no roadmap; Apple publishes none. What can be read:

- WebKit's source for the API, `Source/WebKit/UIProcess/API/Swift/` on github.com/WebKit/WebKit, changes two or
  three times a month. The recent additions are SPI for Apple's own clients — `_editable`, attachment callbacks,
  `_overrideViewportWithArguments`, image controls — and fixes to `backForwardList`. None of it is ours.
- **Nothing there answers a new-window request**: no `createWebView`, no `interactionState`, no find, no icon
  loading in `WebPage.swift` or `WebPage+Configuration.swift` on `main`. Others have hit the same wall and use the
  same workaround Savoia had, treating `action.target == nil` as a new window.
- **Two things there are ours, as SPI.** `WebPage.Configuration.isControlledByAutomation` is `@_spi(Testing)`, and
  its getter and setter are exported by the WebKit of macOS 27.2 (`dyld_info -exports`) — the SDK's interface
  simply leaves it out. And `WebPage.backingWebView` is `@_spi(CrossImportOverlay) public` on `main`: the view
  itself, from the moment the page exists, not only while a pane shows it. It is **not** among the exports of
  macOS 27.2. Also exported: the C function `WKPageSetControlledByAutomation`.
- The next public change is, by Apple's habit, an OS release in June. Watch the directory above, Safari Technology
  Preview's notes, and [api-watch.md](../../api-watch.md).

So waiting buys the backing view at best, and not this year's OS.

## Order

1. **Finish the inventory.** The table above is from memory of the last week. Go through `WebViewResponder`'s nine
   callers and [api-watch.md](../../api-watch.md) and make it complete, with what each workaround costs in lines
   and in limits. One page, in [architecture.md](../../architecture.md) or beside it.
2. **Try the two SPI doors first — an hour.** `isControlledByAutomation` through its exported symbol, or
   `WKPageSetControlledByAutomation` on a page that already exists: does `_WKAutomationSession` then list a
   `WebPage`'s view? If it does, the automation row leaves the table without leaving `WebPage`. Say what was
   called and how; a symbol the SDK does not declare is the same trade as the rest of the SPI in use.
3. **The seam.** Everything `BrowserTab` asks of a page behind one protocol — load, navigation events, the
   decider, dialogs, device permissions, scripts, export, media and capture state, fullscreen, back and forward.
   `WebPage` is its first implementation and nothing behaves differently. This is worth having whichever way the
   decision goes.
4. **The second implementation, behind a switch**: a `WKWebView` Savoia creates, in an `NSViewRepresentable`, with
   its own navigation and UI delegates. `ScriptedPopups` is already this for one kind of window; grow it rather
   than start again. First what a tab cannot do without, then the rows of the table.
5. **A week on it in the dev build**, the wpt permission run both ways (`scripts/permissions-wpt.py`), the key and
   tab self-tests both ways. Then Artem decides.

Steps 1 to 3 are one session. Step 4 is several. Stop after 3 and report before starting 4.

## What it costs, so it is not written down as free

- The premise in AGENTS.md's first paragraph changes, and with it README's pitch.
- `@Observable` state comes free with `WebPage`; on `WKWebView` it is KVO and a wrapper of our own.
- It is the heart of the browser: navigation, certificates, downloads, permissions and dialogs all pass through
  it, and each has a paragraph in AGENTS.md that cost hours.
- Two implementations exist for as long as the switch does.

## Done when

Artem has a build where one environment variable changes what a tab is made of, a page that says what each costs,
and enough days on both to choose. The choice, and why, goes into AGENTS.md.
