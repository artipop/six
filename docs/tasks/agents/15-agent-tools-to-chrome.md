# 15. An agent in Savoia can do what one in Chrome can

Bring the tools an agent gets over `Savoia --mcp` up to Chrome's DevTools MCP server, tool for tool, and keep a
table that says where they stand.

## Why

An agent that drives a browser is judged against the one that drives Chrome. Where Chrome's server has a tool and
Savoia has none, the agent either gives up — an upload — or falls back to hand-written JavaScript through
`evaluate_javascript`, which fails without saying why and runs in the page's own world.

**And with as little script in the page as possible.** That is the other half of the goal, not a detail
([page-scripts.md](../../page-scripts.md)). Chrome reaches a page through the DevTools protocol, from outside it.
Savoia has no such door, but it has two that are not script: a real event handed to the web view, which is how
`click` and `press_key` already work, and the delegate that answers the page's own requests. A new tool takes one
of those wherever it can; a script only finds the element, as it does for `click`.

## Where it stands

Savoia's column is the catalog in `Savoia/Tools/BrowserTools.swift`. Chrome's is from memory of
`chrome-devtools-mcp` — **read its current tool list first and correct this table.**

| Chrome DevTools MCP | Savoia | |
|---|---|---|
| `take_snapshot` | `page_snapshot` | built |
| `click`, `fill`, `fill_form`, `press_key` | `click`, `fill`, `select_option`, `press_key` | built; click and keys are real events |
| `wait_for` | `wait_for` | built |
| `navigate_page`, `new_page`, `list_pages`, `select_page`, `close_page` | `navigate`, `open_window`, `list_workspaces`, `focus_window`, `close_window` | built |
| `evaluate_script` | `evaluate_javascript` | built; no user gesture |
| `take_screenshot` | `take_screenshot` | built |
| `list_console_messages`, `list_network_requests` | the same names | built, only while capture is on ([devtools.md](../../devtools.md)); status and timing, no headers or bodies |
| `hover` | — | missing |
| `drag` | — | missing |
| `upload_file` | — | missing: the agent reaches the button and meets the system's open panel |
| `handle_dialog` | — | missing: `alert`, `confirm` and `prompt` are drawn for a person (`PageDialogs`) |
| `get_network_request` (headers, body) | — | not reachable — below |
| `emulate` (CPU, network), `resize_page` | — | not reachable — below |
| `performance_start_trace`, `…stop_trace`, `…analyze_insight` | — | not reachable — below |

## What to build, and how each stays out of the page

1. **`upload_file`.** No script at all: the file input asks the tab's UI delegate (`PageDelegate`, `runOpenPanelWith`), which
   `PageDialogs` answers. Under an agent's call it is answered with the path the agent gave instead of an
   `NSOpenPanel`. The agent names a file on the person's disk, so this asks, per call, like every acting tool.
2. **`handle_dialog`.** The same door: a dialog a page raises during an agent's turn is reported in the tool's
   result, and the agent accepts or dismisses it. A dialog nobody is driving stays the person's.
3. **`hover`.** A mouse-moved `NSEvent` to the web view, beside `BrowserTab.click(atViewport:)`. Measure first: a
   moved event posted to the app's queue did not drive AppKit's tracking areas, but handing one straight to the
   `WKWebView` has not been tried, and it is the page's `mouseover` that matters here.
4. **`drag`.** Down, dragged, up as real events. HTML drag-and-drop goes through the system's dragging session,
   which may not start from synthetic events — measure on a sortable list and on a file drop zone before promising.

## WebKit's own automation: open now, and a decision

Safari's WebDriver runs on `_WKAutomationSession`, and the session answers protocol messages inside the app with no
safaridriver (`_setMessageToFrontendHandlerForTesting:`, `_dispatchMessageFromRemoteForTesting:`). Measured on
6 October 2026 in a throwaway app: on a `WKWebView` whose configuration was made with `_setControlledByAutomation:`,
`Automation.getBrowsingContexts` lists the page, `evaluateJavaScriptFunction` returns a value with
`userActivation.isActive` false, `takeScreenshot` returns a PNG and `getAllCookies` the cookies.

A tab was a `WebPage` then, which makes its own view, and the door stayed shut. A tab is a `WKWebView` of Savoia's
own now and `BrowserTab.materialize` writes its configuration, so the flag is one line away.
[Task 23](../architecture/23-webpage-or-wkwebview.md) was to set it on every tab and did not, for two reasons to
settle here first:

- **A page can tell.** WebKit's source answers `navigator.webdriver` from the same flag, and a site that reads it
  treats the visitor as a robot. On every tab that is Artem's whole browsing; it belongs on a tab an agent drives,
  which means building that tab's view with the flag — the configuration is read when the view is made — and
  rebuilding it to take the flag off.
- **It was not reproduced.** A second throwaway `WKWebView`, with the flag set by key on the configuration and no
  session attached, hung before its first load (7 October 2026). What the first measurement had that this one
  lacked — a session, a process pool, the order — is the first thing to find out.

## What is not reachable for an agent, and where to stop

Request headers and bodies, throttling, a device viewport and performance traces come from the Web Inspector
protocol. A person can have them: the inspector opens on a tab through SPI
([22-web-inspector-in-savoia.md](../devtools/22-web-inspector-in-savoia.md)). An agent cannot: nothing there sends a
protocol message. A `WKURLSchemeHandler`-shaped proxy would give the bodies at the price of carrying every
request; a WebKit build of Savoia's own is ruled out. Say so in [mcp.md](../../mcp.md) and [devtools.md](../../devtools.md), in the table above, and stop.

## Done when

- The table is checked against Chrome's server as it is today and lives in [agent-actions.md](../../agent-actions.md).
- `upload_file` and `handle_dialog` work through `Savoia --mcp` on a throwaway page; `hover` and `drag` work, or
  it is written down what was measured and why not.
- No new tool runs more script in a page than `click` does.
