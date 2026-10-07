# Developer tools

Two different things: Web Inspector, for a person, and capture under **Configuration ▸ Assistant**, off by
default, for agents.

## Web Inspector

**View ▸ Web Inspector**, `⌥⌘I`, opens WebKit's own inspector on the tab in front and closes it again
(`Savoia/DevTools/WebInspector.swift`). It is the frontend Safari shows — Elements, Console, Sources, Network,
Timelines, Storage, Graphics, Layers, Audit — and there is no switch for it.

All of it is SPI behind `responds(to:)`: `WKWebView._inspector` is a `_WKInspector` with `show`, `attach`,
`detach` and `close`, and none of them does anything unless `developerExtrasEnabled` was set on the
configuration's preferences before the view was made (`BrowserTab.materialize`, every kind of tab). Where the
SPI is absent the menu item is not there.

- **Docked or in a window of its own.** A page at least 0.6 of its window wide gets the inspector docked; one
  of two tabs side by side gets it in WebKit's own window. The frontend puts itself where it last stood while it
  loads, so a `detach` sent straight after `show` is undone; the choice is sent from the delegate's
  `inspectorFrontendLoaded:`. That overrides where the person left it the last time.
- **A docked inspector lives inside `PageHost`'s view**, beside the page, and WebKit resizes the page's view
  itself. It follows the host: the find bar opening above takes its height from the page, not from the
  inspector, and a window resize is followed. `_WKInspector` has nothing that sets the docked height; the
  person drags the divider.
- **An inspected tab is not discarded** (`LivePageCache`, "inspected"), and stays inspected behind another tab
  and across a navigation. A page that is let go anyway — a rebuild, a close — closes its inspector first
  (`BrowserTab.releasePage`), and the tab is built again without one.
- **`⌘W` in the inspector's own window closes that window.** Close Tab is Savoia's only `⌘W`, so it asks whose
  window the key came from (`WebInspector.closeWindow`); without that the key closed the inspected tab.

- **Inspect Element** in the page's context menu is WebKit's own item, the one thing that knows the element
  under the pointer: `PageDelegate` takes it out of the menu WebKit proposed, by its identifier
  `WKMenuItemIdentifierInspectElement`, and puts it last in Savoia's. It opens the inspector where WebKit last
  had it, not where `⌥⌘I` would put it. Not measured: a right click cannot be sent from a test.

`SAVOIA_INSPECTOR_SELFTEST=1` walks all of it with real keys and prints a line per step, among them the
frontend's own account of what it inspects. Given an address instead of `1`, the first page is that one and the
rows of the Console tab are printed too — the one way here to read what WebKit itself wrote to a page's console,
which capture never sees.

Measured in the dev build, in a throwaway home, 7 October 2026, in a 1440×799 window: the page went from 721 to
221 points with the frontend at 500 under it; 191 with the find bar; `⌥⌘I` closed it with the page focused and
with the frontend focused; the frontend named the page's address and the nine panels. Not looked at by a
person: the test reads sizes and the frontend's answers, not the screen. Not measured: the other `⌘` keys
pressed in the inspector's own window, which still reach Savoia's menu.

**Safari no longer attaches.** Until this, `savoia://configuration` ▸ Develop had a switch that set
`WKWebView.isInspectable`, and Safari's Develop menu listed Savoia's pages. The inspector it opened is this one,
so the switch and its setting (`devtools.inspector`) are gone and a page is inspectable by nothing outside
Savoia.

## Capture, for agents

An agent driving the browser does not want an inspector window; it wants its facts. `savoia://configuration` ▸ Assistant ▸
**Access to Page Console and Network** turns on a running record per window — what the page logged, what it
requested — kept in memory and nowhere else, and adds the two MCP tools that read it ([mcp.md](mcp.md)).

The switch lives with the agents and not under Develop because nothing in Savoia shows a person what it records: a
person has the inspector for the same facts, told by the browser rather than by the page. So the tools are not
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
(`Automation.end`). An ordinary tab never carries the flag, so `navigator.webdriver` stays `false` there.

**Two tools, MCP only**, listed while the switch is on: `automation_open_window` opens such a tab, and
`automation_send` passes one command (`method`, `params`) to the session with
`_dispatchMessageFromRemoteForTesting:` and answers with the reply `_setMessageToFrontendHandlerForTesting:`
delivered for its id, as WebKit wrote it; events that arrived since the last command follow it. Savoia assigns the
id. The session's delegate answers two requests: a new web view (`Automation.createBrowsingContext`) is a new
automation tab, and a switch to a web view selects its tab.

**The window is the person's, and the protocol may read it and not move it.** WebKit asks for a window's frame
through the UI delegate — `_webView:getWindowFrameWithCompletionHandler:`, which `PageDelegate` answers with the
frame of the window the view is in — so `windowSize` and `windowOrigin` are the one window's, the origin counted
from the top left of the screen. It is every tab's delegate, and it was every tab's fault: a page read
`outerWidth` and `outerHeight` 0 and `screenY` as the height of the screen until it was answered.
`_webView:setWindowFrame:` is left unanswered, so neither `setWindowFrameOfBrowsingContext` nor a page's
`resizeTo` moves anything. The session delegate's `requestMaximizeWindowOfWebView`, `requestHideWindowOfWebView`
and `requestRestoreWindowOfWebView` are answered at once and do nothing: an automation tab is a tab in the window
somebody is using, and the three have no way to say no, only a completion to call.

**A page's dialog is answered through the protocol.** The delegate's seven dialog requests read the tab's own
pending dialog ([agent-actions.md](agent-actions.md#dialogs-and-files-the-delegates-door)), so
`isShowingJavaScriptDialog`, `messageOfCurrentJavaScriptDialog`, `setUserInputForCurrentJavaScriptPrompt`,
`acceptCurrentJavaScriptDialog` and `dismissCurrentJavaScriptDialog` work, and the sheet a person would have
answered comes down. WebKit holds the reply of a command a dialog interrupts until the dialog is answered, so
`automation_send` ends that wait when the dialog opens (`Automation.dialogOpened`) and the held reply arrives with
the events of a later command.

**The file chooser is WebKit's own under automation, and Savoia is never asked.** A chooser an automation tab opens
is answered by the session with the files `setFilesToSelectForFileUpload` named — they stay named for the session,
not for one use — or cancelled when none were, and `Automation.fileChooserDismissed` says which; more than one file
for an input without `multiple` is a cancel. `PageDelegate.runOpenPanelWith` does not run, so no sheet goes up and
`upload_file` has nothing to answer: on an automation tab it refuses and names the command.

**The protocol's mouse clicks with Savoia behind another app**, because an automation tab's view is an
`AutomatedWebView`, which accepts a first click. WebKit sends its synthesized mouse events to the window with
`sendEvent:`, and a window that is not key hands a mouse-down only to a view that says it takes the first one — a
plain `WKWebView` does not, so the down went nowhere and the up after it. Nothing is brought forward: the app in
front stays in front. Moves do not reach a page behind another app, as for any view
([agent-actions.md](agent-actions.md#hover-and-drag-the-pointer)).

Three things in the protocol that read like Savoia's fault and are not, from WebKit's source
(`SimulatedInputDispatcher.cpp`, `WebAutomationSessionMac.mm`). A mouse state in `performInteractionSequence`
without `mouseInteraction` (`Move`, `Down`, `Up`) is dropped and the command still answers `{}`. Its `origin`
defaults to `Pointer`, so a `location` is added to the last one unless `origin` is `Viewport`. And the button of an
`Up` is its own `pressedButton`: an `Up` without one is sent as a move, and the page never sees `mouseup`.
`performMouseInteraction` with `SingleClick` sends two mouse-downs and no mouse-up on this system's WebKit, in front
too; `Down` and then `Up` click. Keys — `performKeyboardInteractions`, a keyboard source in a sequence — go through
Savoia's own key router.

Measured over `Savoia --mcp` in a throwaway home, 7 October 2026: with the switch off the tools are not listed; with
it on, `Automation.getBrowsingContexts` lists the tab, `evaluateJavaScriptFunction` answers with
`navigator.webdriver` true and `userActivation.isActive` false, `navigateBrowsingContext`, `takeScreenshot`,
`getAllCookies` and `createBrowsingContext` answer; a cookie set in the automation tab is not seen by an ordinary
tab on the same site; the automation tab is in neither `state.json` nor `visits`.
The same day for dialogs: a `confirm` and a `prompt` raised from a timer read as showing, gave their message, and
the page read `true`, `false` after a dismiss, and the text set with `setUserInputForCurrentJavaScriptPrompt`; the
command that armed the timer answered in 0.3 s where it had waited out its 30; an accept with no dialog is
WebKit's `NoJavaScriptDialog`.

The rest was measured the same way later that day, the switch thrown by `testdriver_allow_automation`
([test-suites.md](test-suites.md#what-unlocks-most-of-the-rest-testdriver)). **The switch turned off** with an
automation tab open and a command waiting on a 20 s timer in its page: the command was answered `Automation was
switched off` 2.6 s after it was sent, the switch thrown 2 s in; the tab was gone from `list_workspaces`, both tools from the list, and
`automation_send` was an unknown tool; turned on again, a new tab came up under a new session and
`getBrowsingContexts` listed it alone. **The frame**, in a 1440×799 window on a 1440×900 screen: `windowSize`
1440×799 and `windowOrigin` 0, 30 where they had read 0×0 and 0, 900, and an ordinary tab's `outerWidth`,
`outerHeight` and `screenY` 1440, 799 and 30 where they had read 0, 0 and 900; after `setWindowFrameOfBrowsingContext`
to 700×500, `maximizeWindowOfBrowsingContext` and `hideWindowOfBrowsingContext`, each answered `{}` at once, the
frame read the same. **A file**: with one named, a Space on the focused input and Savoia's `click` on it each left
`files.length` 1, the file's name and a `change`; with none named the chooser was cancelled; two named were a
cancel on a plain input and two files on a `multiple` one. **The orange mark** was seen in a drawing of the window
(`testdriver_window_image`): the capsule stands in the address field, left of the address. **The mouse**, with
Terminal in front before and after: a sequence of `Move`, `Down`, `Up` on a text field gave the page `mousedown`,
`mouseup` and `click`, the same on a file input chose the named file, and `performMouseInteraction` `Down` then `Up`
clicked; on a plain `WKWebView` the window was sent the mouse-down and the view's `mouseDown:` never ran.

Two things that cost time. `setValue(_:forKey:)` with `_controlledByAutomation` never returns — the flag is set by
calling the setter's implementation. And `WKProcessPool` is deprecated in the SDK, so the pool is made and attached
by name to keep the build free of warnings; if pools ever stop being separate, the session would reach every tab's
pool and this needs another look.

### Who speaks to it

An MCP client, one command at a time through `automation_send`, and nothing else. Two larger things were weighed
and declined, 7 October 2026.

**The wpt stand stays on its own testdriver** ([test-suites.md](test-suites.md)). One run of the permission
directories with `--actions`: 356 files, 749 testdriver actions, 10 of them answered "not implemented" in 10
files — nine `bidi.permissions.set_permission` and one `add_virtual_authenticator`. The session answers
`addVirtualAuthenticator`; its BiDi door (`processBidiMessage`) answers that the `permissions` and `emulation`
domains were not found, which rules out the nine and the 21 `bidi.emulation.set_geolocation_override` calls in the
sources that the run never reached. So the protocol would serve one action in one file. The other 242 failed `set_permission` actions are
for a name Savoia keeps no answer for — `clipboard-read`, `clipboard-write`, `geolocation`,
`notifications`, `idle-detection` — which is Savoia's to build and no protocol's; `setSessionPermissions` refuses
`geolocation` as an unknown value too.

**WebDriver over HTTP is not built.** safaridriver does not attach to another browser, so it would be a server of
Savoia's own turning W3C commands into the protocol's. No client is waiting for one; what it would take is
[tasks/devtools/28](tasks/devtools/28-webdriver-http.md).

## What is not here

No DOM snapshot with stable element ids, no synthetic clicks and typing, no performance traces, no request
interception or throttling — the things Chrome's devtools MCP has beyond this. Most of them need the inspector
protocol, which an app cannot reach for its own pages; a build of WebKit of Savoia's own would, and is ruled
out — the inspector above is a window for a person, and nothing in `_WKInspector` sends a protocol message. `evaluate_javascript` covers a
surprising amount of it for now ([mcp.md](mcp.md)), and the rest is in [todo.md](todo.md).
