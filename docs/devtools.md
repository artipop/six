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
A tab behind another is in no window and is answered with the window there is.
`_webView:setWindowFrame:` is left unanswered, so neither `setWindowFrameOfBrowsingContext` nor a page's
`resizeTo`, `moveTo` or `resizeBy` moves anything — measured. The session delegate's `requestMaximizeWindowOfWebView`, `requestHideWindowOfWebView`
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

An MCP client, one command at a time through `automation_send`, and a WebDriver client, through the server below.
The wpt stand was first kept on its own testdriver (7 October 2026) and moved to wptrunner a day later, when the
server existed ([test-suites.md](test-suites.md#the-wpt-stand)).

## WebDriver over HTTP

While Allow Remote Automation is on, Savoia answers W3C WebDriver on loopback, and each command becomes one or
more of the protocol's — what safaridriver does for Safari, which does not attach to another browser. The
client it was built for and measured with is wptrunner; Selenium and WebdriverIO speak the same commands and
were not tried. There is no driver binary: the browser is its own.
`Savoia/DevTools/WebDriverServer.swift` is the listener and the session, `WebDriverWire.swift` the half that is
bytes and JSON (in `SavoiaCore`, with tests), and WebKit's `Source/WebDriver/Session.cpp` was the reference for
which protocol command each one becomes.

**Before writing it** a Swift WebDriver *server* was looked for and not found — the Swift packages are clients
(thebrowsercompany/swift-webdriver, GetAutomaApp/SwiftWebDriver), and the servers are for iOS apps
(XCTestWD, WebDriverAgent). For HTTP the candidates were FlyingFox, Hummingbird and Swifter; the listener is
`NWListener` and a parser of sixty lines instead, because a WebDriver client sends one small JSON body with a
`Content-Length` over a kept-alive connection and nothing else, and a package would be another pin in two graphs.

**Where it listens.** `127.0.0.1`, on the port `SAVOIA_WEBDRIVER_PORT` names or one the system picks at launch,
shown in Configuration under the switch and written to the log; only while the switch is on, and turning it off
ends the session. There is no password, as with safaridriver: any program on the Mac can drive an automation
tab while the switch is on. A *page* cannot — a request that carries an `Origin`, or a `Host` that is not
`localhost`, `127.0.0.1` or `[::1]`, is answered 403, which is what stops a form posted across origins and a name
rebound to loopback.

**One session at a time.** New Session opens an automation tab; Delete Session closes every one and ends the
protocol's session (`Automation.end`). `acceptInsecureCerts` is refused — an authority is trusted in
Configuration ([certificates.md](certificates.md)), and a session that waved every certificate through would be
the one place Savoia does — `setWindowRect` is false: the window is the person's, so
Set Window Rect, Maximize, Minimize and Fullscreen answer with where the window is and move nothing.

**The commands.**

| WebDriver | the protocol |
|---|---|
| New Session, Delete Session, Status, Get and Set Timeouts | Savoia's own; `getBrowsingContexts`, `switchToBrowsingContext` |
| Navigate To, Back, Forward, Refresh | `navigateBrowsingContext` and its siblings, with the session's page load strategy |
| Get Current URL, Get Title, Get Page Source | `getBrowsingContext`, `evaluateJavaScriptFunction` |
| Get Window Handle(s), Switch To Window, New Window, Close Window | `getBrowsingContexts`, `switchToBrowsingContext`, `createBrowsingContext`, `closeBrowsingContext` |
| Switch To Frame (index, element, null), Switch To Parent Frame | `resolveChildFrameHandle`, `resolveParentFrameHandle` |
| Get Window Rect, and the four that would move it | `getBrowsingContext` |
| Find Element(s), from an element and from a shadow root; Get Active Element, Get Element Shadow Root | `evaluateJavaScriptFunction` |
| Get Element Text, Tag Name, Attribute, Property, CSS Value, Rect; Is Selected, Enabled, Displayed; Computed Role and Label | `evaluateJavaScriptFunction`, `computeElementLayout`, `getComputedRole`, `getComputedLabel` |
| Element Click | `computeElementLayout`, then `performMouseInteraction` Down and Up (or `selectOptionElement`), then `waitForNavigationToComplete` |
| Element Clear, Element Send Keys | `evaluateJavaScriptFunction`; `performKeyboardInteractions`, or `setFilesForInputFileUpload` for a file input |
| Execute Script, Execute Async Script | `evaluateJavaScriptFunction` |
| Get All Cookies, Get Named Cookie, Add Cookie, Delete Cookie, Delete All Cookies | `getAllCookies`, `addSingleCookie`, `deleteSingleCookie`, `deleteAllCookies` |
| Perform Actions, Release Actions | `performInteractionSequence`, `cancelInteractionSequence` |
| Dismiss Alert, Accept Alert, Get Alert Text, Send Alert Text | the protocol's four dialog commands |
| Take Screenshot, Take Element Screenshot | `takeScreenshot` |
| Set Permission | `setStorageAccessPermissionState` for `storage-access`; `SitePermissions` for the rest — below |
| Set Storage Access, Generate Test Report | `setStorageAccessPolicy`, `generateTestReport` |

Everything else is `unknown command`: Print Page, the virtual authenticator (the protocol has it; nobody has
asked), the sensor, device posture, FedCM, Global Privacy Control, bounce tracking,
web extensions and the rest of what wptrunner's executor can send, and all of WebDriver BiDi
([tasks/devtools/33](tasks/devtools/33-playwright-bidi.md)). Element Text is `innerText` and Is Displayed is
`checkVisibility`, not the Selenium atoms.

**Three things the server does that the protocol does not.**

- *A window in a script's answer.* The protocol serializes a `Window` as the cyclic object it is and fails
  (`cannot serialize cyclic structures`) — Safari's wpt runs end in ERROR on every file whose testdriver call
  carries one. The client's script is wrapped, and a window leaves as WebDriver writes one, `window-fcc6…` for a
  top one and `frame-075b…` for a frame, with an empty handle: the protocol names no handle for an arbitrary window.
- *Close Window waits.* `closeBrowsingContext` answers before the tab is gone, and Close Window's answer is the
  handles that are left; a tab still there half a second later is closed by Savoia, and its page with `_close`.
  A `WKWebView` held anywhere is a browsing context still listed — holding the view across that wait kept every
  closed window open, and one window that stays open fails every file after it, since wptrunner closes them all
  before each. The other way to the same failure was Savoia's own and older than the server: a closed tab whose
  picture was still being taken built itself a second view (`BrowserTab.page` from `rememberViewState`), a
  browsing context with no address and no tab. A tab now closes its page with `_close` when it is an automation
  tab, and the picture's task uses the view it started with.
- *A new tab settles first.* A tab is made loading its blank page, and a navigation asked for at once was
  answered by that load ending: the page read `about:blank` a moment later. New Window and New Session wait for it.

**Which tab a handle is** the protocol does not say, and Set Permission needs the tab. The top frame is given a
property with a random name through the protocol, each automation tab's view is asked for it without a gesture,
and the one that has it deletes it.

**What Safari mocks on wpt's CI, and what Savoia does the same way.** Almost nothing is set up from outside:
wpt's workflow for Safari (`.github/workflows/safari-wptrunner.yml`) runs `sudo safaridriver --enable`, writes the
hosts file, clears the caption profile and passes two capabilities, `acceptInsecureCerts` and
`webkit:alwaysAllowAutoplay`. The rest is WebKit's automation session, read from its source, and three of its
pieces are for the *browser* to apply, which Safari does out of sight and Savoia does in `Automation.prepare`:

| what a test meets | in Safari under automation | in an automation tab |
|---|---|---|
| `getUserMedia` | no prompt: WebKit grants or denies by the session's `GetUserMedia` permission, on by default (`UserMediaPermissionRequestManagerProxy`), before any delegate is asked | the same code; Set Permission for `camera` or `microphone` also goes to `setSessionPermissions` |
| the camera and microphone themselves | mock devices — inferred: wpt's runners have no camera and Safari passes 366 of 482 there | `_setMockCaptureDevicesEnabled:` on the tab's preferences, always; nothing real is switched on |
| autoplay | `webkit:alwaysAllowAutoplay`, a field of `_WKAutomationSessionConfiguration` that WebKit itself never reads | the same capability, as `mediaTypesRequiringUserActionForPlayback = []` |
| capture on plain http, ICE candidates | `webkit:WebRTC` — `DisableInsecureMediaCapture`, `DisableICECandidateFiltering` | the same capability, as the two preferences |
| Set Permission for `storage-access` | `setStorageAccessPermissionState`, per frame; safaridriver answers `not implemented` for the other names | the same command; the other names are Savoia's, below |
| Set Storage Access, Generate Test Report | `setStorageAccessPolicy`, `generateTestReport` | the same commands |
| a page's dialog, a file chooser | the session's, no sheet | the same ([above](#remote-automation)) |

Mock devices are an inference and not a reading: Safari's side is closed. What stands behind it: with them on,
`MediaStreamTrack-getCapabilities` gives Safari's 80 of 112 where this Mac's camera gave 76. And for the
protocol's storage-access command: `storage-access-api` went from 27 files of 40 the same as Safari with
Savoia's own call and the two origins — the rest asked for a gesture after the permission was granted — to 34
with the command, and to all 40 once the view left by a closed tab was gone
([test-suites.md](test-suites.md#the-wpt-stand)).

**Set Permission is Savoia's** for every other name, as it was the old runner's: `SitePermissions` for the origin
of the frame the session is in, and an unknown name is `invalid argument`. For
`camera` and `microphone` the answer also goes to `setSessionPermissions`, because under automation WebKit lets a
page capture without asking the delegate at all — measured: with `camera` denied `getUserMedia` resolved until it
did. Three commands are Savoia's own, under `/session/{id}/savoia/`: `permissions` (Set Permission with the
`origin` named, which is what BiDi's takes), `geolocation` (the stand-in position) and `reset` (what one test
file must not leave for the next) — `TestDriver.swift`'s code behind another door.

**Measured**, 8 October 2026, in a throwaway home: every command in the table by hand over `curl`-like
requests (a session, scripts with elements and windows in their answers, a click that gave the page
`userActivation`, typed text with a held Shift, a pointer and a key sequence, frames by index and back, a second
tab opened, switched to and closed, cookies added, read and deleted, a dialog dismissed and reported, a request
with an `Origin` refused 403), and then wptrunner over the twelve permission directories.

**What an automation tab is not, and what the stand does about it.**

- *Its store is not kept, and WebKit gives such a store no notifications*: `Notification.permission` is `denied`
  whatever was answered. Under `SAVOIA_TESTDRIVER` an automation tab is given its profile's store
  (`Automation.dataStore`), in the throwaway home the stand runs in; without the variable it is as described above.
- *WebKit's question about storage access has nobody to answer it.* For an automation tab `PageDelegate` answers
  no (`_webView:requestStorageAccessPanelForDomain:…`, which it says it responds to only for such a tab); a client
  that wants the access sets the permission. Unanswered, the alert came up over whatever was in front for the
  whole run and kept its tab from closing.
- *`⌘C` `⌘V` `⌘X` `⌘A` are the Edit menu's actions* in an `AutomatedWebView`, as they were in the old runner's
  key: the menu bar leaves Paste off on a page with nothing editable.
- `SitePermissions`, the permission bar and geolocation behave as in an ordinary tab — the profile is the one in
  front when the tab was opened.

## What is not here

No DOM snapshot with stable element ids, no synthetic clicks and typing, no performance traces, no request
interception or throttling — the things Chrome's devtools MCP has beyond this. Most of them need the inspector
protocol, which an app cannot reach for its own pages; a build of WebKit of Savoia's own would, and is ruled
out — the inspector above is a window for a person, and nothing in `_WKInspector` sends a protocol message. `evaluate_javascript` covers a
surprising amount of it for now ([mcp.md](mcp.md)), and the rest is in [todo.md](todo.md).
