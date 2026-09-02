# Developer tools

Two different things, both under the **Develop** menu, both off by default.

## Web Inspector

`WebPage.isInspectable`, and that is the whole of it. **six has no inspector window of its own, and cannot have
one**: WebKit lets an app declare its pages inspectable, and nothing more — opening an inspector on your own page
is `_WKInspector`, which is private API. What the switch does is let *Safari's* Web Inspector attach, and that one
is the real thing — elements, console, network, sources, breakpoints.

**How to attach**, once `six://settings` ▸ **Develop** ▸ Allow Safari to Inspect six's Pages is on:

1. In Safari: **Settings › Advanced › Show features for web developers**. Without it Safari's own Develop menu is
   hidden and there is nowhere to attach from. (This is the usual reason "I turned it on and nothing happened".)
2. Safari's menu bar: **Develop › ‹the name of this Mac› › six › ‹the page's title›**.
3. The window has to be showing a *page*. A fresh window in six is the start page, which is SwiftUI rather than web
   content, so it has nothing to inspect; so does a window whose page was discarded by the memory budget until you
   scroll back to it.

six's settings page carries the same instruction under the switch, with this Mac's name filled in, and
turning the switch on writes it to stderr as well.

Off by default because an inspectable page is one another process on the machine can attach to. The switch applies
to the pages that are open at once, and to every page built after it.

## Capture, for agents

An agent driving the browser does not want an inspector window; it wants its facts. `six://settings` ▸ Develop ▸ **Capture Console and
Network** turns on a running record per window — what the page logged, what it requested — and three MCP tools read
it ([mcp.md](mcp.md)):

| tool | what it answers |
|---|---|
| `list_console_messages` | what the page logged since it last navigated, with uncaught errors and unhandled rejections; `level` filters |
| `list_network_requests` | the requests it made — method, status, duration, size, kind; `failed_only` narrows to errors and 4xx/5xx |
| `take_screenshot` | writes a PNG of the whole page (not the visible part) under `Application Support/org.deffun.six/Screenshots/` and returns the path |

`take_screenshot` works whether or not capture is on. The other two say plainly that capture is off rather than
answering with an empty list — and because the hooks are installed at the *start* of a load, turning capture on
reloads the open windows.

Each window keeps its last 500 console messages and 500 requests, and both are cleared when the window navigates:
what was captured belonged to the page being left.

## How the capture works, and what it costs

WebKit gives an app no API for a page's console or its resource loads, and the Web Inspector protocol is not
reachable from the app hosting the page. So six instruments the page: a `WKUserScript` at document start that wraps
`console.*`, listens for `error` and `unhandledrejection`, wraps `fetch` and `XMLHttpRequest`, and runs a
`PerformanceObserver` over resource timing for everything the page did not request by hand (scripts, images,
stylesheets, media).

**That script runs in the page's own world, which is a deliberate exception to how six works.** Everything else six
injects lives in a `WKContentWorld` of its own precisely so a page cannot see or touch it
([architecture.md](architecture.md#page-side-scripts)) — but `console.log` and `fetch` *are* the page's globals, and
wrapping them anywhere else would wrap nothing.

The consequences, stated rather than hidden:

- the page can see the wrappers, can replace them, and can post to the message handler itself — so what comes back
  is the page's account of itself, not the browser's;
- the handler's name is different on every launch, so a page cannot count on finding it;
- capture is off by default, and is meant to be turned on while debugging something, not left on.

What it does not see: requests made before the script runs are caught only by resource timing (URL, kind and
duration, no status), request and response *bodies* and headers are not recorded at all, and sizes come from
`transferSize`, which is zero for a cross-origin response without `Timing-Allow-Origin`. `no-cors` responses are
opaque and report status 0 — shown as `opaque`, and not counted as failures.

The hooks live in the window's `WKUserContentController` — the same one that carries the blocker's rules, which is
why both now go through [`PageControllers`](../six/Browser/PageControllers.swift) rather than belonging to either.

## What is not here

No DOM snapshot with stable element ids, no synthetic clicks and typing, no performance traces, no request
interception or throttling — the things Chrome's devtools MCP has beyond this. Most of them need the inspector
protocol, which is why they share a fate with the in-window inspector: see
[todo.md](todo.md#someday-sixs-own-webkit-build). `evaluate_javascript` covers a
surprising amount of it for now ([mcp.md](mcp.md)), and the rest is in [todo.md](todo.md).
