# JavaScript Savoia runs in pages

Every place Savoia executes or injects script in a page, why each one is a liability, and what is to become of it.
Written in October 2026, after the wpt permission run ([permissions.md](permissions.md#compatibility-web-platform-tests))
showed two things about `WKWebView.callAsyncJavaScript`, the public call into a page.

## What a call costs

- **It is a user gesture.** Measured in the page's world: after the public call, with no click,
  `navigator.userActivation.isActive` is true for about a second, `navigator.clipboard.writeText()` and `readText()`
  resolve, and a `postMessage` or zero-delay timer started from it inherits the same. `hasBeenActive` stays true
  for the life of the document. A call in the `savoia` world does the same as one in the page's: activation
  belongs to the window and not to the world (measured in a bare `WKWebView`, where a load alone, a load with a
  user script, and the gesture-free call all leave it false).
- **A script that moves the page moves it when nobody asked.** Two of them scroll.
- **A user script is in every frame of every page it is installed for**, and is one more thing between a page
  and the browser it expects. It is not why `PaymentRequest` is `undefined`: a bare `WKWebView` has none either
  ([tasks/browser/32](tasks/browser/32-apple-pay-switch.md)).

## One door

Savoia does not make that call. Everything it runs in a page goes through `WKWebView.callWithoutGesture`
(`PageScripts.swift`): WebKit's `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:`
with `false`, SPI, behind `responds(to:)` — the public call is left only for the SPI being absent. The other names
are that call with a world filled in: `WKWebView.savoia` (Savoia's world), `WKWebView.callJavaScript` (the page's),
`BrowserTab.callWithoutGesture` (the tab's view) and `BrowserTab.runScript` (the same, and only while the tab has a
page). What gives a page activation is what a person or an agent does to it: a click or a key, which `click`,
`testdriver_click` and `testdriver_key` send as real events.

Measured over `Savoia --mcp` in a throwaway home, 8 October 2026, `navigator.userActivation` read with
`evaluate_javascript` on a fresh page each time: `isActive` and `hasBeenActive` both false after `get_selection`,
`get_page_links`, `list_page_blocks`, `highlight_page`, `add_bookmark`, Save As as HTML and as text
(`testdriver_export`), `get_page_content`, `web_search`, a page opened by a highlight's link (which landed on the
highlight, 2521 px down), and `call_page_tool`; true after `testdriver_click` and after `testdriver_key`, the
controls. ⌘E on a selection, pressed as its menu item by `SAVOIA_KEY_SELFTEST=assistant`: false, and true in the
same run with the gesture put back. The rest of that self-test, and `SAVOIA_WEBMCP_SELFTEST`, read the same either way.

**The page's world goes without a gesture too**, by choice:

- **A WebMCP tool call** (`call_page_tool`, and the registry's own questions to the page, one of which runs at every
  navigation). The call is an agent's, not a click of the person's, and a page that got activation from it could
  open a window or read the clipboard on an agent's word — the reason `evaluate_javascript` has none. A tool that
  needs activation is refused by the API it calls and can say so in its answer; the agent has `click`.
- **A message to an MCP app** (`MCPAppSession.deliver`). Messages arrive by themselves, and the app's frame is
  activated by the person clicking in it, as any frame is.

## Every way into a page

Code reaches a page in three ways — a call, a script installed ahead of a load, and WebKit's own machinery — and
activation in one: an event. Each row is a door; nothing else runs in a page.

**Calls.** All but the last two are `WKWebView.callWithoutGesture`.

| door | whose code | world | frame | opened by | in which tabs |
|---|---|---|---|---|---|
| `savoia`, `runScript`, `BrowserTab.callWithoutGesture` | Savoia's, fixed function bodies | savoia | main | Savoia: the events in [Runs by itself](#runs-by-itself), and the tools and commands in [On request](#on-a-persons-or-an-agents-request) | every web tab |
| `evaluate_javascript` | the caller's | the page's | main | the assistant, an ACP agent, an MCP client | every web tab |
| `testdriver_in_context` | the caller's | the page's | any, by the name testdriver gave it | an MCP client, under `SAVOIA_TESTDRIVER` | every web tab |
| WebMCP — `call_page_tool`, and the registry's questions | Savoia's body, calling a tool the page declared | the page's (the `allow` attribute is read in savoia) | the tool's own | an agent, after the site was allowed; the registry at each navigation | while Develop ▸ WebMCP is on |
| the MCP app bridge — `MCPAppSession.deliver` | Savoia's body, posting one message | the page's | main, the app's shell | a message from the app's server | an MCP app's tab |
| `Automation.evaluateJavaScriptFunction` | the client's, and the WebDriver server's own bodies for finding and reading elements | the page's | the frame the client switched to | `automation_send` over MCP; a WebDriver client's Execute Script and element commands ([devtools.md](devtools.md#webdriver-over-http)) | automation tabs, while Develop ▸ Allow Remote Automation is on |
| the WebDriver server's mark — `WebDriverSession.tab` | Savoia's, one property set through the protocol and deleted through `callWithoutGesture` | the page's | main | Set Permission and Close Window, to learn which tab a handle is | automation tabs |
| Web Inspector's console | the person's | the page's | any | ⌥⌘I | every web tab |

None of them is a user gesture: the first five by `withUserGesture: false`, the protocol's by WebKit (measured,
[devtools.md](devtools.md#remote-automation)). The inspector's console is WebKit's and was not measured.

**Installed ahead of a load.** User scripts on the tab's `WKUserContentController`, kept by name in
[`PageControllers`](../Savoia/Browser/PageControllers.swift); the table is [below](#injected-ahead-of-time).
An extension's content scripts are the extension's, in a world WebKit makes for it, and an automation tab has no
extension controller.

**Events.** What a page takes for a person: `click`, `hover`, `drag`, `press_key`, `testdriver_click` and
`testdriver_key` hand an `NSEvent` to the view, and the protocol's `performInteractionSequence` has WebKit
synthesize one. A click and a key activate the page (measured, above).

### What overlaps, and what was closed

- **Three doors run a caller's code in the page's world**: `evaluate_javascript`, `testdriver_in_context` and the
  protocol's `evaluateJavaScriptFunction`. They are one call apart from each other in the first two cases — the
  test driver's adds the choice of a frame — and the third is WebKit's. They stay three because they answer three
  clients: an agent, the wpt stand, a WebDriver client. `testdriver_in_context` goes with the stand's move to
  wptrunner ([devtools.md](devtools.md#webdriver-over-http)), where the protocol's own call does its work.
- **Two ways to click, and two to answer a dialog**: Savoia's event and the protocol's, `handle_dialog` and the
  protocol's dialog commands. Each pair ends in the same place — the view's `mouseDown`, the tab's pending dialog —
  and they are compared in [agent-actions.md](agent-actions.md) and [devtools.md](devtools.md#remote-automation).
- **An automation tab is left alone at a load.** The offer to translate, the highlights and the description for
  groups do not run in it: the tab is its client's, and a person's highlight painted into a test's document is a
  document the test did not load. The live-page budget still asks it about unsent input and a floating video before
  discarding it, in Savoia's world. Measured on an address with a stored highlight: `CSS.highlights.size` 1 in an
  ordinary tab and 0 in an automation tab, read with the protocol's own call.
- **Closed, with no script left**: the site icon, find on page, the scroll offset, the selection for ⌘E as a user
  script, and the media hold where the SPI is there. **Closed as a gesture**: every call. **Behind a switch that is
  off**: the blocker's page half, and the description for groups.

**What activated every page at load** was three calls, found with a page that writes
`navigator.userActivation` into its own title, read with `list_workspaces` so that nothing is run to read it:

- the offer to translate — `PageTranslator.plan` on every `.finished`, through `BrowserTab.runScript`;
- any call at `.finished` on a page that loaded fast, while a tab was a `WebPage`: the load ended before the pane
  had found the web view, and the call fell back to the ordinary one — a fallback that is gone, with the search for
  the view;
- the live-page budget asking a page off screen whether a video of it is floating
  (`WKWebView.isInPictureInPicture`).

All three go without a gesture now, as every call does. With them
`hasBeenActive` is false after a load, after a load of an address that has a highlight (which is painted), in a
second window opened straight after, and on a page the budget looked at and kept.

## Runs by itself

| what | when | world | does | decision |
|---|---|---|---|---|
| the page's size, for its picture — `BrowserTab.rememberViewState` | a tab leaving the screen, at most every 3 s | savoia | reads `innerWidth` and `innerHeight` | stays. The scroll offset is no longer read here, nor put back by a script — below |
| site icon | — | — | — | **done**: no script. WebKit names and fetches the icons, `SiteIcons` is the view's icon-loading delegate ([architecture.md](architecture.md)) |
| description for groups — `TabSorter.pageFinished` | every `.finished`, while Tabs ▸ groups by meaning is on (off by default) | savoia | reads the meta description or the first paragraph | stays: on titles alone the groups are worse ([layout.md](layout.md#groups-by-meaning)) |
| highlights — `HighlightStore.apply` | a load of an address that has highlights | savoia | edits the DOM, watches it for 5 s | stays; below |
| the offer to translate — `BrowserState.offerTranslation` | every `.finished` | savoia | reads the page's language and a sample of its text | stays |
| unsent input — `BrowserTab.hasUserInput` | the live-page budget choosing what to discard | savoia | reads `textarea` and password fields | stays |
| a floating video — `WKWebView.isInPictureInPicture` | the same | savoia | reads each `video`'s presentation mode | stays |

## Injected ahead of time

| what | where | decision |
|---|---|---|
| `AdvancedRules` — the blocker's scriptlets and extended CSS | the main frame of a page a filter list has such rules for, while Privacy ▸ Blocking ▸ Cosmetic Rules and Scriptlets is on | a setting, **off by default** ([blocking.md](blocking.md)). Scriptlets go into the page's world, by design |
| `PageFocus` — the selection and caret for ⌘E | — | **done**: nothing is installed; `PageFocusStore.refresh` reads the page when ⌘E is pressed. A line hung on a field no longer follows it as the page scrolls |
| `MediaHold` — holds autoplay | — | **done**: no script. A preference of the view for the one load after a tab is rebuilt; the script is left for the SPI being absent ([architecture.md](architecture.md#persistence)) |
| DevTools capture, the WebMCP polyfill | only while switched on, every frame | stay |
| the MCP app bridge | an MCP app's tab, which is no site's page | stays ([mcp-apps.md](mcp-apps.md)) |

## On a person's or an agent's request

| what | decision |
|---|---|
| find on page | **done**: `WKWebView.find`, no script in the page; `FindScript` is gone. The bar says only when there is nothing, since the public API gives no count |
| translation | stays; `savoia` world |
| the readable copy for bookmarks, Save As, the accessibility overlay, going to a highlight, the selection for ⌘E, `web_search`, `get_selection`, `get_page_links`, `list_page_blocks`, `highlight_page` | stay; `savoia` world, on demand |
| agent tools — `page_snapshot`, `click`, `fill`, `scroll_page`, `evaluate_javascript` | `savoia` world, `evaluate_javascript` the page's; `click` is a real mouse event, and the one gesture ([agent-actions.md](agent-actions.md#the-acting-tools)) |
| a page's own tools — `list_page_tools`, `call_page_tool` | the page's world ([webmcp.md](webmcp.md)) |

## Scroll and history: `interactionState`

`WKWebView.interactionState` is the back-forward list with each entry's scroll position, restored the way Safari
restores a tab. It replaced both scroll scripts: nothing reads `scrollY` and nothing calls `scrollTo`.

- **Taken** from the tab's web view in `discard()`, and for a live tab as the snapshot is written — synchronously,
  with no round trip to the page. A state above 512 KB is not written to the snapshot (`history.state` can be
  megabytes, and the snapshot is rewritten on every change); it is still kept in memory across a discard.
- **Kept** in `BrowserTab.savedState`, in `Trail` for a move between profiles, and as `TabSnapshot.state` in
  `state.json` — about 1 KB for three entries.
- **Given** to the view as the tab resumes (`BrowserTab.resumeIfNeeded`), in place of loading the address, on
  screen or not: a tool that reads a waiting tab gets the page where it was left. The load arrives as an ordinary
  started, committed, finished. To the page it is a `back_forward` navigation.
- **No addresses beside it.** The lists of addresses a tab used to keep and walk (`savedBack` / `savedForward`)
  were for a view that could not be reached; they are gone. A tab with no state — one over the limit after a
  relaunch, a file from before states were kept — comes back at its address with no history.

Measured over `Savoia --mcp`: a tab off screen, after the page budget took its page and after a relaunch, was back
on its last page with `history.back()` leading to the one before and the scroll at 1500 where it was left.

**Limits, accepted.** WebKit puts the offset back once, at load. Content that is in the document by then is
restored exactly; content added afterwards — 50 ms after is enough — is not waited for, and the page lands at the
bottom of what there was (offset 558 of 6000 on the stand's page). The script it replaced clamped the same way.
A `textarea`'s text did not come back in the measurement. A scroll made after the last change to the model is in
the file only after a quit: nothing rewrites the snapshot on scroll.

Checked through `Savoia --mcp` in a throwaway home: `testdriver_discard_pages` gives back every page off screen
(the budget never goes under ten under memory pressure, so `SAVOIA_LIVE_PAGES=1` alone does not), and
`SAVOIA_PAGE_CACHE_DEBUG=1` says which way a page resumed.

## Highlights

`highlight_page`, `list_highlights`, `remove_highlight` and `cite` are in the catalog, `HighlightStore.apply` paints
a stored highlight again on a load, and the research preset tells the agent to highlight what it cites
([deep-research.md](deep-research.md)). The one way to start a run is `/research` on the ⌘E line. A run on
6 October 2026 stored thirteen highlights on thirteen pages. Who chooses the paragraphs is the model ⌘E is set to;
with an agent there, the agent calling the tool chooses.
