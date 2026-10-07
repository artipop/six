# 15. An agent in Savoia can do what one in Chrome can

Bring the tools an agent gets over `Savoia --mcp` up to Chrome's DevTools MCP server, tool for tool. `handle_dialog`
and `upload_file` are built, and the table that says where each tool stands is in
[agent-actions.md](../../agent-actions.md#against-chromes-server). What is left is `hover` and `drag`.

## Why

An agent that drives a browser is judged against the one that drives Chrome. Where Chrome's server has a tool and
Savoia has none, the agent either gives up — an upload — or falls back to hand-written JavaScript through
`evaluate_javascript`, which fails without saying why and runs in the page's own world.

**And with as little script in the page as possible.** That is the other half of the goal, not a detail
([page-scripts.md](../../page-scripts.md)). Chrome reaches a page through the DevTools protocol, from outside it.
Savoia has no such door, but it has two that are not script: a real event handed to the web view, which is how
`click` and `press_key` already work, and the delegate that answers the page's own requests. A new tool takes one
of those wherever it can; a script only finds the element, as it does for `click`.

## What to build, and how each stays out of the page

1. **`hover`.** A mouse-moved `NSEvent` to the web view, beside `BrowserTab.click(atViewport:)`. Measure first: a
   moved event posted to the app's queue did not drive AppKit's tracking areas, but handing one straight to the
   `WKWebView` has not been tried, and it is the page's `mouseover` that matters here.
2. **`drag`.** Down, dragged, up as real events. HTML drag-and-drop goes through the system's dragging session,
   which may not start from synthetic events — measure on a sortable list and on a file drop zone before promising.

## WebKit's own automation: built, as a mode

Remote automation is built the way Safari has it — a switch that is off, and tabs opened under it that are apart
from the rest — and is described in [devtools.md](../../devtools.md#remote-automation): `automation_open_window` and
`automation_send` over MCP. It is not on ordinary tabs, because a page reads the flag as `navigator.webdriver`.

What it leaves for this task: `hover` and `drag` are still to be built on Savoia's own page actions, which
work on every tab; the protocol is a second way to the same page for a client that wants WebDriver's semantics.
Not built on it: the delegate's window-geometry requests, a WebDriver endpoint over HTTP, and the wpt
stand, which still drives pages with its own testdriver ([test-suites.md](../../test-suites.md)).

## What is not reachable for an agent, and where to stop

Request headers and bodies, throttling, a device viewport and performance traces come from the Web Inspector
protocol. A person can have them: the inspector opens on a tab through SPI
([22-web-inspector-in-savoia.md](../devtools/22-web-inspector-in-savoia.md)). An agent cannot: nothing there sends a
protocol message. A `WKURLSchemeHandler`-shaped proxy would give the bodies at the price of carrying every
request; a WebKit build of Savoia's own is ruled out. Say so in [mcp.md](../../mcp.md) and [devtools.md](../../devtools.md), in the table in [agent-actions.md](../../agent-actions.md#against-chromes-server), and stop.

## Done when

- `hover` and `drag` work through `Savoia --mcp` on a throwaway page, or it is written down what was measured and
  why not, and the table in [agent-actions.md](../../agent-actions.md#against-chromes-server) says so.
- No new tool runs more script in a page than `click` does.
