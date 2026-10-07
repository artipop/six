# Developer tools

Two different things, both off by default: Web Inspector under **Develop**, for a person, and capture under
**Configuration ▸ Assistant**, for agents.

## Web Inspector

`WKWebView.isInspectable`, and that is the whole of it. **Savoia has no inspector window of its own, and cannot have
one**: WebKit lets an app declare its pages inspectable, and nothing more — opening an inspector on your own page
is `_WKInspector`, which is private API. What the switch does is let *Safari's* Web Inspector attach, and that one
is the real thing — elements, console, network, sources, breakpoints.

**How to attach**, once `savoia://configuration` ▸ **Develop** ▸ Allow Safari to Inspect Savoia's Pages is on:

1. In Safari: **Settings › Advanced › Show features for web developers**. Without it Safari's own Develop menu is
   hidden and there is nowhere to attach from. (This is the usual reason "I turned it on and nothing happened".)
2. Safari's menu bar: **Develop › ‹the name of this Mac› › Savoia › ‹the page's title›**.
3. The window has to be showing a *page*. A fresh window in Savoia is the start page, which is SwiftUI rather than web
   content, so it has nothing to inspect; so does a window whose page was discarded by the memory budget until you
   scroll back to it.

Savoia's settings page carries the same instruction under the switch — naming "this computer's name" rather than
filling it in, since a Sharing name read back in Savoia's own caption looked like something Savoia had invented — and
turning the switch on writes it, name and all, to the log.

Off by default because an inspectable page is one another process on the machine can attach to. The switch applies
to the pages that are open at once, and to every page built after it — the second half is set in
`BrowserTab.materialize`, and for a while the web-page branch there did not set it, so after a relaunch no page was
inspectable and Safari listed no Savoia.

## Capture, for agents

An agent driving the browser does not want an inspector window; it wants its facts. `savoia://configuration` ▸ Assistant ▸
**Access to Page Console and Network** turns on a running record per window — what the page logged, what it
requested — kept in memory and nowhere else, and adds the two MCP tools that read it ([mcp.md](mcp.md)).

The switch lives with the agents and not under Develop because nothing in Savoia shows a person what it records: a
person has Safari's inspector for the same facts, told by the browser rather than by the page. So the tools are not
offered at all while it is off — `tools/list` leaves them out and `notifications/tools/list_changed` goes to whoever
is connected when it flips, since a tool that can only answer "turn something on first" is one a model keeps
calling.

| tool | what it answers |

|---|---|
| `list_console_messages` | what the page logged since it last navigated, with uncaught errors and unhandled rejections; `level` filters |
| `list_network_requests` | the requests it made — method, status, duration, size, kind; `failed_only` narrows to errors and 4xx/5xx |
| `take_screenshot` | writes a PNG of the visible part of the page (`WKWebView.takeSnapshot`; measured 2880×1442 on a 1440-point column, before the move to `WKWebView` and after) under `Application Support/org.deffun.savoia/Screenshots/` and returns the path |

`take_screenshot` is there whether or not capture is on. Because the hooks are installed at the *start* of a load,
turning capture on reloads the open windows.

Each window keeps its last 500 console messages and 500 requests, and both are cleared when the window navigates:
what was captured belonged to the page being left.

### The one entry that does not come from the page

A main frame that failed its provisional load has no page to instrument — the certificate did not check out, the host
did not resolve, the connection was refused — so the one request that matters is the one request capture cannot see.
`BrowserTab` hands it over instead (`DevToolsStore.noteLoadFailure`), and it arrives as a console **error** and a
failed `document` request, so `list_console_messages` and `list_network_requests` both carry it. It survives the
window's next navigation being cleared, because a failed navigation never commits one.

The same failure goes to the log whether or not capture is on, since it is the answer to *why is this window blank*
and the only copy that outlives the window — under the `load` category, in the file and in Console
([logging.md](logging.md)):

```
2026-09-09 14:30:31.108 [load] error: https://alfabank.ru/ failed: The certificate for this
server is invalid. … (NSURLErrorDomain -1202) — Savoia carries ru.trusted-ca, switched off
```

The clause after the dash is [the certificate offer](certificates.md#when-it-fails-anyway).

## How the capture works, and what it costs

WebKit gives an app no API for a page's console or its resource loads, and the Web Inspector protocol is not
reachable from the app hosting the page. So Savoia instruments the page: a `WKUserScript` at document start that wraps
`console.*`, listens for `error` and `unhandledrejection`, wraps `fetch` and `XMLHttpRequest`, and runs a
`PerformanceObserver` over resource timing for everything the page did not request by hand (scripts, images,
stylesheets, media).

**That script runs in the page's own world, which is a deliberate exception to how Savoia works.** Everything else Savoia
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
why both now go through [`PageControllers`](../Savoia/Browser/PageControllers.swift) rather than belonging to either.

## Remote automation

`savoia://configuration` ▸ Develop ▸ **Allow Remote Automation**, off by default, is Safari's switch of the same name
done in-process: WebKit's automation — `_WKAutomationSession`, the thing safaridriver drives Safari through — for
tabs opened under it, and for no other tab. All of it is SPI behind `responds(to:)`
(`Savoia/DevTools/Automation.swift`); where it is absent the section does not show.

**An automation tab** (`BrowserTab.isAutomated`) is built on a configuration with `_setControlledByAutomation:` and a
process pool that carries the session. It has the session's own non-persistent store, no extension controller, is
left out of history, the snapshot and the closed-tab list, and shows an orange **Automation** mark in the address
field. A window such a tab opens is one too. Turning the switch off closes them and ends the session
(`Automation.end`); that path was not exercised. An ordinary tab never carries the flag, so `navigator.webdriver`
stays `false` there.

**Two tools, MCP only**, listed while the switch is on: `automation_open_window` opens such a tab, and
`automation_send` passes one command (`method`, `params`) to the session with
`_dispatchMessageFromRemoteForTesting:` and answers with the reply `_setMessageToFrontendHandlerForTesting:`
delivered for its id, as WebKit wrote it; events that arrived since the last command follow it. Savoia assigns the
id. The session's delegate answers two requests: a new web view (`Automation.createBrowsingContext`) is a new
automation tab, and a switch to a web view selects its tab. The dialog and window-geometry requests are not
answered, so `windowSize` reads 0×0 and a page's `alert` is not reachable through the protocol.

Measured over `Savoia --mcp` in a throwaway home, 7 October 2026: with the switch off the tools are not listed; with
it on, `Automation.getBrowsingContexts` lists the tab, `evaluateJavaScriptFunction` answers with
`navigator.webdriver` true and `userActivation.isActive` false, `navigateBrowsingContext`, `takeScreenshot`,
`getAllCookies` and `createBrowsingContext` answer; a cookie set in the automation tab is not seen by an ordinary
tab on the same site; the automation tab is in neither `state.json` nor `visits`.

Two things that cost time. `setValue(_:forKey:)` with `_controlledByAutomation` never returns — the flag is set by
calling the setter's implementation. And `WKProcessPool` is deprecated in the SDK, so the pool is made and attached
by name to keep the build free of warnings; if pools ever stop being separate, the session would reach every tab's
pool and this needs another look.

safaridriver does not attach to Savoia, so nothing speaks WebDriver over HTTP here; a client speaks the protocol
through `automation_send`.

## What is not here

No DOM snapshot with stable element ids, no synthetic clicks and typing, no performance traces, no request
interception or throttling — the things Chrome's devtools MCP has beyond this. Most of them need the inspector
protocol, which an app cannot reach for its own pages; a build of WebKit of Savoia's own would, and is ruled
out. The inspector itself can be opened on a tab ([tasks/devtools/22](tasks/devtools/22-web-inspector-in-savoia.md)). `evaluate_javascript` covers a
surprising amount of it for now ([mcp.md](mcp.md)), and the rest is in [todo.md](todo.md).
