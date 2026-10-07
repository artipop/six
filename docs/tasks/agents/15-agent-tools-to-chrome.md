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

## WebKit's own automation: reachable now, and not used

Safari's WebDriver runs on `_WKAutomationSession`, and the session answers protocol messages inside the app with no
safaridriver (`_setMessageToFrontendHandlerForTesting:`, `_dispatchMessageFromRemoteForTesting:`). Measured on
6 October 2026 in a throwaway app: on a `WKWebView` whose configuration was made with `_setControlledByAutomation:`,
`Automation.getBrowsingContexts` lists the page, `evaluateJavaScriptFunction` returns a value with
`userActivation.isActive` false, `takeScreenshot` returns a PNG and `getAllCookies` the cookies.

A tab was a `WebPage` then, which makes its own view, and the door stayed shut. A tab is a `WKWebView` of Savoia's
own now and `BrowserTab.materialize` writes its configuration, so the flag can be set.

**Decided by Artem on 7 October 2026: it is not set — not on every tab, and not for the tests either.**

- **It is a tool for tests, and gives a person nothing.** WebKit's source answers `navigator.webdriver` from the
  same flag, so on an ordinary tab a site would see a robot. The flag is read when the view is made and the view
  has no setter, so a tab cannot be put under automation without building its view again.
- **The flag alone works, and does nothing by itself.** Measured on 7 October 2026 on a throwaway `WKWebView`,
  with the flag set through `_setControlledByAutomation:` itself: the view is made, the page loads and
  `navigator.webdriver` is `true`, with a `_WKAutomationSession` on the process pool (`_setAutomationSession:`) and
  without one. Driving the page still takes the session and code that speaks its protocol. An earlier note here
  said a flagged tab does not load; that was the measurement's own fault — `setValue(_:forKey:)` with
  `_controlledByAutomation` never returns, and the hang was that call, in the probe and in Savoia alike. Call the
  setter, not KVC.
- **An agent gains little.** A script with no gesture, a screenshot and the cookies are what Savoia's own tools
  already do. What an agent lacks — request bodies, throttling, traces — is the inspector's protocol, below.
- **The wpt stand already has a testdriver.** It was written because wptrunner drives Safari through safaridriver,
  which cannot attach to Savoia, and because the flag could not be set at all then
  ([test-suites.md](../../test-suites.md)). Moving the stand onto WebKit's automation would buy the actions the
  stand answers "not implemented", done by WebKit itself, at the price of the session and a bridge to wptrunner.

Come back to this only if those unimplemented testdriver actions start to cost runs.

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
