# 23. A tab is a `WKWebView` of Savoia's own

Move every tab off SwiftUI's `WebPage` onto a `WKWebView` that Savoia creates, and then take out the workarounds
`WebPage` made necessary. Decided by Artem on 7 October 2026. **No switch between the two and no second
implementation kept alive**: the aim is fewer seams, not one more.

## Why

Savoia was built on `WebView`/`WebPage` on purpose. A year in, almost everything added begins with "`WebPage` has no
way to…, so take the view": the `WKWebView` behind a page is reached through `WebViewResponder`, a walk of the view
tree that only finds a view while its tab is on screen. Savoia pays for both models — it lives by `WebPage`'s rules
and works through a `WKWebView` it does not own.

Waiting does not close the gap. WebKit's source for the API
(`Source/WebKit/UIProcess/API/Swift/` on github.com/WebKit/WebKit, read on 6 October 2026) has nothing for a
new-window request, session state, find or icons; what it gains month to month is SPI for Apple's own clients.
The one thing in it that would have helped, `WebPage.backingWebView`, is SPI on `main` and not in macOS 27.2
([api-watch.md](../../api-watch.md)).

## What it buys — each row was a wall that was measured

| what | on `WebPage` | on our own view |
|---|---|---|
| `window.open` | a separate `NSWindow` (`ScriptedPopups`) | an ordinary tab with its opener, as in Safari |
| WebKit's automation, for an agent's tools | lists no page for a `WebPage`'s view ([15](../agents/15-agent-tools-to-chrome.md)) | works — measured on a view made controlled by automation |
| extension pages, an extension's new-tab page | a window of their own | tabs, from `WKWebExtensionContext.webViewConfiguration` |
| session state: scroll and history | only once a pane has shown the tab; address lists otherwise | before the tab is shown |
| a script with no user gesture | a page off screen gets the ordinary call, which is a gesture | always |
| geolocation, notifications | a delegate placed in front of `WebPage`'s own | our own delegate |
| element fullscreen | black without a temporary hold, and a workaround for navigating out of it | to be retested; the hold exists because of how SwiftUI's `WebView` holds the view |
| a web archive in Save As | `WebPage` has no `createWebArchiveData` | `WKWebView` has it |
| autoplay held after a tab is rebuilt | a user script (`MediaHold`) | `mediaTypesRequiringUserActionForPlayback`, to be checked on macOS |

What it does **not** change: Apple Pay (cause unknown), Web Push, the inspector's protocol for an agent, the C API
behind geolocation and notification providers.

## What goes away with `WebPage`, and has to be rebuilt first

- **Observation.** `WebPage` is `@Observable`; `url`, `title`, `isLoading`, progress, the capture and fullscreen
  states are read straight from it. On `WKWebView` they are KVO, published through `BrowserTab`.
- **The navigation feed** — `page.navigations` and `apply(_:of:)` — becomes a `WKNavigationDelegate`:
  the decider (`TabNavigationDecider`), the response policy, the authentication challenge for
  `CertificateStore`, started, committed, finished, failed.
- **`WebPage.DialogPresenting`** becomes the `WKUIDelegate` methods `PageDialogs` already answers one layer down:
  alert, confirm, prompt, the open panel.
- **`deviceSensorAuthorization`** becomes `requestMediaCapturePermissionFor` and
  `requestDeviceOrientationAndMotionPermissionFor`, into `SitePermissions` as now.
- **The three SwiftUI modifiers**: back and forward gestures (`allowsBackForwardNavigationGestures`), element
  fullscreen (`preferences.isElementFullscreenEnabled`), and the page's context menu (`.pageContextMenu` — today
  SwiftUI's; on a `WKWebView` it is `willOpenMenu` in a subclass).
- **`callJavaScript`, `exported(as:)`, `load`, `reload`, the back-forward list, `isInspectable`** have direct
  counterparts. About 86 call sites name a member of the page; most go through `page.savoia` and
  `BrowserTab.runScript`, which are the two places to change.

Each of these has a paragraph in AGENTS.md that cost hours — the throwing navigation feed, `⌘W`, the `.disabled`
on `Commands`, the letter bindings. Read "Things that have cost hours" before touching the part it is about.

## Order

On a branch, `wkwebview`, merged when it is whole: a tab half on each model is not a state `main` should be in,
and a branch is not a switch. If Artem would rather have it on `main` in steps, ask before starting.

1. **The mapping, written down.** Every `WebPage` member Savoia uses → its `WKWebView` counterpart, and every
   workaround that exists only because of `WebPage` → what replaces it. Start from the lists above, the nine files
   that call `WebViewResponder.shared`, and [api-watch.md](../../api-watch.md). One table, kept in
   [architecture.md](../../architecture.md).
2. **The tab's view.** `BrowserTab` creates and owns a `WKWebView`; one `NSViewRepresentable` shows it in
   `TabPageView` and `DocumentView`. Navigation and UI delegates, the KVO, the scripts. At the end of this step
   the browser works as it did and nothing uses `WebPage`.
3. **Take the workarounds out, one commit each**, and check each against what it was for:
   - `WebViewResponder`'s walk of the view tree, and "only while on screen" everywhere it is written;
   - `ScriptedPopups`' window and its proxy delegate — a script-opened window becomes a tab with its opener
     ([03-popups.md](../browser/03-popups.md) changes shape, or closes);
   - the address lists beside `interactionState`, and the wait for a pane to find the view;
   - `callWithoutGesture`'s fallback to the ordinary call;
   - the fullscreen hold (`PageElementFullscreen`) and `leaveElementFullscreen` — retest with each removed;
   - `MediaHold`, if the configuration's own setting does the same;
   - extension pages in a window of their own (`ExtensionStore.openExtensionPage`).
4. **What it opens**: Save As to a web archive; the automation flag on every tab, which changes how
   [15](../agents/15-agent-tools-to-chrome.md) is built.
5. **The words.** AGENTS.md's first paragraph and "Where things are", README's pitch,
   [architecture.md](../../architecture.md), [api-watch.md](../../api-watch.md) (most of its rows resolve),
   [page-scripts.md](../../page-scripts.md), [links.md](../../links.md), [todo.md](../../todo.md), and the tasks
   this one changes: 3, 15, 17, 20, 22.

Stop and report after step 2, before deleting anything in step 3.

## Checking it

- Every self-test that exists, before and after: `SAVOIA_KEY_SELFTEST` (and `=assistant`, `=chats`),
  `SAVOIA_TABS_SELFTEST`, `SAVOIA_FIND_SELFTEST`, the translation and topics ones.
- `./scripts/permissions-wpt.py` against its baseline, and `./scripts/webmcp-wpt.py`. A `REGRESSION` line is a
  defect; a `NEW PASS` is expected where a window used to be a separate one.
- By hand, with Artem, because no test covers them: a certificate error and the page for it, a download, a
  ⌘-click, back and forward by swipe, a video in fullscreen, picture-in-picture, the camera in a call, an
  extension's popup, the context menu, find, translation, ⌘E on a selection, a discarded tab coming back.
- The dev Mac has 8 GB: compare memory with ten tabs before and after.

## Done when

No file imports `WebPage`'s API, the workarounds in step 3 are gone or each has a line saying why it stayed, the
self-tests and both wpt runs are no worse, the hand list is walked, and the docs describe a browser built on
`WKWebView`.
