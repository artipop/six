# JavaScript Savoia runs in pages

Every place Savoia executes or injects script in a page, why each one is a liability, and what is to become of it.
Written in October 2026, after the wpt permission run ([permissions.md](permissions.md#compatibility-web-platform-tests))
showed two things about `WebPage.callJavaScript`.

## What a call costs

- **It is a user gesture.** Measured in the page's world: after `evaluate_javascript`, with no click,
  `navigator.userActivation.isActive` is true for about a second, `navigator.clipboard.writeText()` and `readText()`
  resolve, and a `postMessage` or zero-delay timer started from it inherits the same. `hasBeenActive` stays true
  for the life of the document. A call in the `savoia` world does the same as one in the page's: activation
  belongs to the window and not to the world (measured in a bare `WebPage`, where a load alone, a load with a user
  script, and the gesture-free call all leave it false).
- **A script that moves the page moves it when nobody asked.** Two of them scroll.
- **A user script on every page is a condition WebKit can see.** `PaymentRequest` and `ApplePaySession` are
  `undefined` in Savoia (measured), and still are with the blocker's page scripts off. The cause was not
  established ([todo.md](tasks/browser/11-page-scripts-rest.md)).

The call that carries none is `BrowserTab.callWithoutGesture` (`PageScripts.swift`): WebKit's
`_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:`, SPI, behind
`responds(to:)`. It needs the tab's `WKWebView`, which a pane finds a moment after it is mounted: a call for a
page on screen waits for that (`WebViewResponder.awaitedWebView`, a second at most), and a page no pane shows gets
the ordinary call. Measured through it: `isActive` false, and a clipboard write with no click is refused.

**What activated every page at load** was three calls, found with a page that writes
`navigator.userActivation` into its own title, read with `list_workspaces` so that nothing is run to read it:

- the offer to translate — `PageTranslator.plan` on every `.finished`, through `BrowserTab.runScript`;
- any call at `.finished` on a page that loads fast: the load ended before the pane had found the web view (67 ms
  before, on a local page), and the call fell back to the ordinary one;
- the live-page budget asking a page off screen whether a video of it is floating
  (`WebPage.isInPictureInPicture`).

All three go without a gesture now, and so do the highlights put back on a load and `hasUserInput`. With them
`hasBeenActive` is false after a load, after a load of an address that has a highlight (which is painted), in a
second window opened straight after, and on a page the budget looked at and kept.

## Runs by itself

| what | when | world | does | decision |
|---|---|---|---|---|
| the page's size, for its picture — `BrowserTab.rememberViewState` | a tab leaving the screen, at most every 3 s | savoia | reads `innerWidth` and `innerHeight` | stays; no gesture. The scroll offset is no longer read here, nor put back by a script — below |
| site icon | — | — | — | **done**: no script. WebKit names and fetches the icons, `SiteIcons` is the view's icon-loading delegate ([architecture.md](architecture.md)) |
| description for groups — `TabSorter.pageFinished` | every `.finished` | savoia | reads the meta description or the first paragraph | **done**: `savoia` world, no gesture |
| highlights — `HighlightStore.apply` | a load of an address that has highlights | savoia | edits the DOM, watches it for 5 s | no gesture; below |
| the offer to translate — `BrowserState.offerTranslation` | every `.finished` | savoia | reads the page's language and a sample of its text | stays; no gesture |
| unsent input — `BrowserTab.hasUserInput` | the live-page budget choosing what to discard | savoia | reads `textarea` and password fields | stays; no gesture |
| a floating video — `WebPage.isInPictureInPicture` | the same | savoia | reads each `video`'s presentation mode | stays; no gesture |

## Injected ahead of time

| what | where | decision |
|---|---|---|
| `AdvancedRules` — the blocker's scriptlets and extended CSS | every page while blocking is on | **off for now**, back with `SAVOIA_ADVANCED_RULES=1`. `PaymentRequest` is still `undefined` without them, so they are not why |
| `PageFocus` — the selection and caret for ⌘E | — | **done**: nothing is installed; `PageFocusStore.refresh` reads the page when ⌘E is pressed. A line hung on a field no longer follows it as the page scrolls |
| `MediaHold` — holds autoplay | one load after a tab is rebuilt, every frame | stays |
| DevTools capture, the WebMCP polyfill | only while switched on | stay |

## On a person's or an agent's request

| what | decision |
|---|---|
| find on page | **done**: `WKWebView.find`, no script in the page; `FindScript` is gone. The bar says only when there is nothing, since the public API gives no count |
| translation | stays; `savoia` world, no gesture (`BrowserTab.runScript`) |
| the readable copy for bookmarks, export, the accessibility overlay, going to a highlight, the selection for ⌘E, `get_selection`, `get_page_links`, `list_page_blocks`, `highlight_page` | stay; `savoia` world, on demand, and still a gesture each — `page.savoia` |
| agent tools — `page_snapshot`, `click`, `fill`, `scroll_page`, `evaluate_javascript` | all run without a gesture; `click` is a real mouse event instead ([agent-actions.md](agent-actions.md#the-acting-tools)) |

## Scroll and history: `interactionState`

`WKWebView.interactionState` is the back-forward list with each entry's scroll position, restored the way Safari
restores a tab. It replaced both scroll scripts: nothing reads `scrollY` and nothing calls `scrollTo`.

- **Taken** from the tab's web view (`WebViewResponder`) in `discard()`, and for a live tab as the snapshot is
  written — synchronously, with no round trip to the page. Only a web view that has been on screen is on file; a
  page a tool loaded in the background has no state, and neither has one above 512 KB (`history.state` can be
  megabytes, and the snapshot is rewritten on every change).
- **Kept** in `BrowserTab.savedState`, in `Trail` for a move between profiles, and as `TabSnapshot.state` in
  `state.json` — about 1 KB for three entries.
- **Given** to the fresh web view where a pane finds it (`BrowserTab.webViewFound`, from `onWebViewFound`), in
  place of loading the address. `WebPage` takes it: `url`, `backForwardList` and `navigations` agree afterwards,
  and the load arrives as an ordinary `startedProvisionalNavigation`, `committed`, `finished`. To the page it is a
  `back_forward` navigation.
- **The addresses stay** (`savedBack` / `savedForward`) for the cases with no web view to give a state to: a
  waiting tab a tool reads before it is shown, a state that was not taken, a file from before. When the state is
  given, the addresses WebKit's list has again are dropped from them.

A pane's `onAppear` waits a second for the web view and then loads the address. A tool that reads a waiting tab
which is on screen waits the same way; off screen it loads the address and the state is lost. `focus_window` does
not resume a tab, so the pane does.

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
