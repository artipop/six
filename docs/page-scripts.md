# JavaScript Savoia runs in pages

Every place Savoia executes or injects script in a page, why each one is a liability, and what is to become of it.
Written in October 2026, after the wpt permission run ([permissions.md](permissions.md#compatibility-web-platform-tests))
showed two things about `WebPage.callJavaScript`.

## What a call costs

- **It is a user gesture.** Measured in the page's world: after `evaluate_javascript`, with no click,
  `navigator.userActivation.isActive` is true for about a second, `navigator.clipboard.writeText()` and `readText()`
  resolve, and a `postMessage` or zero-delay timer started from it inherits the same. On a blank page nobody had
  clicked, reached only through a gesture-free call, `hasBeenActive` was already true — so something Savoia runs at
  load activates every page. Not measured: whether a call in the `savoia` world does the same. Activation belongs
  to the window and not to the world, so it probably does.
- **A script that moves the page moves it when nobody asked.** Two of them scroll.
- **A user script on every page is a condition WebKit can see.** `PaymentRequest` and `ApplePaySession` are
  `undefined` in Savoia (measured). Whether user scripts are the cause is a guess; the region of the Apple ID is
  another candidate.

The call that carries none is `BrowserTab.callWithoutGesture` (`PageScripts.swift`): WebKit's
`_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:`, SPI, behind
`responds(to:)`. It needs the tab's `WKWebView`, which exists only for a page some pane has shown; any other page
gets the ordinary call. Measured through it: `isActive` false, and a clipboard write with no click is refused.

`hasBeenActive` is still true on every load, on three origins in a row from an empty window, after every call
Savoia makes at load was moved to the gesture-free one. What sets it has not been found.

## Runs by itself

| what | when | world | does | decision |
|---|---|---|---|---|
| scroll put back — `BrowserTab.restoreScrollIfNeeded` | `.finished`, after a discard or a relaunch | savoia | `window.scrollTo(0, offset)`, once | replace with WebKit's own session state (`interactionState`), if it can be had — below |
| scroll remembered — `BrowserTab.rememberViewState` | a tab leaving the screen, at most every 3 s | savoia | reads `scrollY` | no gesture now; goes with the one above |
| site icon — `SiteIcons.ask` | every `.finished` | **page** | starts a fetch, then polls up to 20 times at 150 ms | no gesture now; later: read the `<link rel=icon>` once and fetch it with `URLSession` |
| description for groups — `TabSorter.pageFinished` | every `.finished` | savoia | reads the meta description or the first paragraph | **done**: `savoia` world, no gesture |
| highlights — `HighlightStore.apply` | a load of an address that has highlights | savoia | edits the DOM, watches it for 5 s | below |
| unsent input — `BrowserTab.hasUserInput` | the live-page budget choosing what to discard | savoia | reads `textarea` and password fields | stays |

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
| find on page — `FindScript` builds its own ranges and scrolls with `scrollBy({behavior: 'smooth'})` | `SAVOIA_NATIVE_FIND=1` switches ⌘F to `WKWebView.find`, with no script in the page; the default is still `FindScript`. The public API gives no "2 of 5", so the bar says only when there is nothing |
| translation, the readable copy for bookmarks, export, the accessibility overlay, going to a highlight | stay; `savoia` world, on demand |
| agent tools — `page_snapshot`, `click`, `fill`, `scroll_page`, `evaluate_javascript` | all run without a gesture; `click` is a real mouse event instead ([agent-actions.md](agent-actions.md#the-acting-tools)) |

## `interactionState`, and what is not known about it

`WKWebView.interactionState` is the back-forward list with each entry's scroll position and form state, restored
the way Safari restores a tab. It would replace both scroll scripts and the hand-kept lists of addresses
([architecture.md](architecture.md)). `WebPage` does not hand it out ([api-watch.md](api-watch.md)); the
`WKWebView` behind a tab is reachable through `WebViewResponder`, but only while the tab is on screen, and
restoring means setting the state on a fresh view instead of loading an address. Whether a `WebPage` survives its
view being given a state behind its back has not been tried.

## Highlights

The code is whole: `highlight_page`, `list_highlights`, `remove_highlight` and `cite` are in the catalog,
`HighlightStore.apply` runs on a load, and the research preset still tells the agent to highlight what it cites
([deep-research.md](deep-research.md)). The one way to start a run is `/research` on the ⌘E line. There is no
`highlights.json` on the dev Mac under either build, so no highlight has ever been stored there; whether a run
today produces any has not been tried.
