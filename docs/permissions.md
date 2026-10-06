# Site permissions

What a page is allowed to do with the machine, and who does the asking. Two things live here: the devices a site can
ask for (camera, microphone, motion sensors) and the four dialogs a page can put up (`alert`, `confirm`, `prompt`, the
file picker). They share a file's worth of thinking because they share a cause — a `WebPage` left alone answers both
kinds of question by itself, and both of its answers are wrong for a browser.

## The default Savoia replaced

`WebPage.Configuration.deviceSensorAuthorization` defaults to `WKPermissionDecision.prompt`. That is not "nothing
works": WebKit puts up a permission popover of its own, the user answers it, and `getUserMedia()` resolves. Camera and
microphone worked in Savoia before any of this existed.

What the default cannot do is *remember*. Nothing is written down, so the same site asks on every load, and there is
nowhere to go and take an answer back. That is the whole reason `SitePermissions` exists: deciding the request
ourselves is what buys the memory and the undo, and the bar under the window's title bar is what it costs.

`WebPage.DialogPresenting` is the harsher default. With no presenter, all four dialogs return "no" —
`alert()` shows nothing, `confirm()` is false, and `<input type="file">` opens no panel and selects nothing. That is
not a policy, it is a browser that quietly cannot upload a file. `PageDialogs` presents them.

## Where an answer is filed

Per **origin** — `https://example.com`, port included when it is not the scheme's own — and per profile. Not per host:
the same host over plain HTTP is a different site to the web platform, and WebKit hands the request to us as a
`WKSecurityOrigin` precisely because that is the boundary that matters. `SitePermissions.origin(of:)` builds the same
string from a `URL` so the title bar can look up what a window was answered without waking its page; the two functions
sit next to each other because they have to agree.

The camera and the microphone are stored separately even though WebKit asks about them together
(`WKMediaCaptureType.cameraAndMicrophone`): a call asks for both at once, and a page that later wants the microphone
alone should not have to ask again. The bar is one question, the records are two. Reading them back, one "no" among
them is a no — half a call is not what either answer meant.

A **private profile's** answers are held for as long as the profile is open and never reach the database
(`SitePermissions.save` filters them out through `isPrivate`, wired at launch the way `HighlightStore`'s is). Removing
a profile forgets what its sites were told.

## The bar, not a sheet

The question is drawn in the column that asked, under that window's own title bar. A sheet belongs to the app, and in
a strip of twenty windows the page that wants the camera is one column of twenty — stopping the other nineteen to
answer for it would be a browser mistaking a page for itself.

It is a sibling of the web view in the column's stack rather than something drawn over it, which is also how it
escapes the problem behind [`HostedOverlay`](../Savoia/Views/HostedOverlay.swift): SwiftUI drawn over a `WKWebView` never
sees the mouse, and a permission bar whose buttons cannot be clicked is worse than no bar.

While the bar is up the page's `getUserMedia()` is suspended inside the decision closure. So a question that can never
be answered has to be answered anyway: closing the window, or giving its page back to the live-page budget, resolves
every question queued for it with a no (`SitePermissions.forget(_:)`, called from `BrowserTab.discard()` and
`close()`). A promise that never lands is a page that never finds out.

A navigation is the third way a question loses its page. Until October 2026 it did not lose its bar: the window
went on to another address with the previous page's question still drawn over it, and an answer given then was
filed under the origin that had left. `BrowserTab.apply(.committed)` now calls the same `forget(_:)`. Each question
is a line in the log when it is asked, answered or dropped (`[pages] permission …`), which is how this was seen.

## In the title bar

- The **lock (or globe)** becomes a menu once the site has been answered about anything: flip an answer, forget the
  site's choices, or open the whole list. Sites with nothing decided keep a plain icon — a control that is always
  there and usually empty teaches people to ignore it.
- The **camera / microphone / screen indicators** are one button per device (`BrowserTab.capturingDevices`), each
  only while that device is in use, red while it is live. A call holds two, and they mute separately — a camera
  turned off while the microphone stays on is the ordinary case; a single button that muted everything and showed
  only the camera's icon left the microphone with no control of its own. Muted, not stopped: `setCameraCaptureState(.muted)` keeps the
  call up and tells the page it was muted, which is what the button in a call's own toolbar does. Blocking a device
  from the site menu *does* stop it (`.none`) — an answer that only applies to the next call is not an answer.

Both read `tab.livePage`, never `tab.page`. A title bar is drawn for every column in the strip, and reaching for the
page would build one for each of them just to ask whether the camera is on (see `BrowserTab.page`).

`savoia://configuration` ▸ **Privacy** ▸ Site Permissions lists every site with a remembered answer, across profiles, with a switch per device
and an `×` that makes the site ask again.

## macOS is asking too

Granting here is not the end of it. The camera and the microphone are behind TCC, and the system's own prompt — the
one `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` fill in, in
[`InfoPlist.xcstrings`](../Savoia/InfoPlist.xcstrings) — comes **first**, before Savoia's bar, and comes once for the app
rather than once per site. Measured, not assumed: on the first `getUserMedia({audio: true})` of a fresh install the
system asks "Разрешить приложению «Savoia» доступ к микрофону?", and only once that is answered does WebKit call the
decision closure and Savoia's own bar appear. So the very first request a user ever makes costs two answers, and every
one after it costs at most one.

Savoia is not sandboxed ([build.md](build.md)), so there are no `com.apple.security.device.*` entitlements in play; the
usage strings and a signed bundle are the whole requirement. If either string were missing the request would
be denied with no prompt at all, which is why they are there and why they are localized.

## Screen sharing, which WebKit asks for by itself

`getDisplayMedia()` needs no delegate and no question of Savoia's own. When the UI delegate does not implement the
private `_webView:requestDisplayCapturePermissionForOrigin:…`, WebKit goes straight to macOS's content-sharing picker
(`SCContentSharingPicker`, presented from its GPU process) and hands the page whatever the person picked. Measured
before a line of code was written for it: a `video:Screen` track came back, and `ScreenCaptureKitCaptureSource::stop`
was in the log the moment the page stopped that track. The picker *is* the consent, so nothing is filed per site —
every browser asks this one every time.

The page has to have focus. From a window of an app that is not in front, WebKit refuses with `InvalidStateError:
Document is not fully active or does not have focus` before any picker appears, which is also why a call made over
`Savoia --mcp` only works while Savoia is the front app.

What `WebPage` leaves out is that sharing is *happening*: it publishes `cameraCaptureState` and
`microphoneCaptureState` and nothing for the screen. `DisplayCapture` reads it from the `WKWebView` underneath,
handed over by `WebViewResponder.onWebViewFound`: `_displayCaptureState` is SPI but KVO-compliant, and
`_setDisplayCaptureState:completionHandler:` mutes it. That drives an indicator of its own beside the camera's, and
`LivePageCache` now keeps any capturing page alive — which camera and microphone calls had been missing too, since
only "playing media" protected them, and only when the page happened to be showing a video.

The observer hangs on the web view as an associated object, so it lives exactly as long as the view it watches.
Both SPI calls sit behind `responds(to:)`: a macOS that drops them loses the indicator, not the sharing.

## A fourth question, which is not a device

`SitePermission.pageTools` is the answer to "may agents use the tools this site offers them?" — WebMCP, and
[webmcp.md](webmcp.md) has the feature. It is filed here rather than anywhere of its own because it is the same
shape of answer: one site, one decision, remembered per profile, taken back from this panel. What differs is what
asks. A device is asked for by the page; this is asked for by an **agent**, at its first call — and a second
question follows it for anything the page did not mark `readOnlyHint`, naming the tool and its arguments. That one
is never remembered (`SitePermissions.Ask.pageToolCall`).

Two consequences worth knowing. The bar draws a sentence now (`Question.prompt` for Windows and Linux, a localized
`switch` in `PermissionBar` on the Mac) rather than a list of device names. And a database written by this build is
one an older build reads badly: `sitePermissions` decodes the list whole, so a row saying `pageTools` makes every
answer about every site unreadable — the same trap `location` set below.

## Compatibility: web-platform-tests

`scripts/permissions-wpt.py` runs twelve wpt directories — `permissions`, `permissions-request`,
`permissions-revoke`, `permissions-policy`, `mediacapture-streams`, `screen-capture`, `mediacapture-handle`,
`geolocation`, `notifications`, `clipboard-apis`, `storage-access-api`, `idle-detection` — in a Debug Savoia it
launches itself in a throwaway home, and compares every file with the newest stable Safari run on wpt.fyi. The bar
is Safari's result for the same file, not the absolute number: a failure Safari shares is WebKit's. It prints the
Safari version of the run beside the system's, since they differ (27.0 on wpt.fyi against 27.2 here). testdriver
is carried the way wptrunner carries it to Safari ([test-suites.md](test-suites.md#what-unlocks-most-of-the-rest-testdriver)).

On wpt `1d99362`, 6 October 2026, baseline in `scripts/permissions-wpt-baseline.json`: 377 addresses, 21 left out,
356 run, **309 the same as Safari, 47 not**.

| directory | run | same | differ |
|---|---|---|---|
| `permissions`, `-request`, `-revoke` | 22 | 22 | 0 |
| `permissions-policy` | 117 | 104 | 13 |
| `mediacapture-streams` | 52 | 47 | 5 |
| `mediacapture-handle` | 1 | 1 | 0 |
| `geolocation` | 22 | 22 | 0 |
| `notifications` | 29 | 27 | 2 |
| `clipboard-apis` | 61 | 52 | 9 |
| `storage-access-api` | 40 | 26 | 14 |
| `idle-detection` | 12 | 8 | 4 |

The 21 left out call `getDisplayMedia()` — all of `screen-capture` and six files of `mediacapture-streams`. The
system's sharing picker waits for a person, the page needs focus, and Savoia is not in front during a run; with
`--screen` they run, for whoever will sit and answer.

The 47, by cause:

| files | what differs | why | state |
|---|---|---|---|
| 8 in `storage-access-api`: `requestStorageAccess`, `-cross-site-iframe`, `-nested-cross-site-iframe`, `-cross-origin-iframe-navigation-relax`, four `storage-access-beyond-cookies.*` | Savoia finishes, Safari's row is a timeout | Safari's run of 6 October timed out where its run of the 5th had not; the comparison is with one run of Safari, and Safari moves between runs | nothing to do |
| 6 in `storage-access-api`: `-cross-origin-iframe-navigation`, `-cross-site-sibling-iframes`, `-sandboxed-iframe-allow-storage-access`, `-web-socket`, `storage-access-permission`, `beyond-cookies.thirdPartyBlobStorage` | Savoia fails or times out | 30 testdriver actions there name a frame the runner did not find (`no such frame`) — likely a frame in a window the test opened, which the runner does not search; not established per file | open, the runner's |
| 7: `permissions-policy/payment-*`, `reporting/payment-reporting` | Safari passes the "allowed" cases | `PaymentRequest` and `ApplePaySession` are `undefined` in Savoia — measured, and still so with the blocker's page scripts off. Why is not established: the region of the Apple ID, or what WebKit gives an app that is not Safari | open |
| 7: `clipboard-copy-selection-line-break` (4), `paste-on-detaching-iframe`, two `focus-without-user-activation-disabled-*` | Savoia fails | they call `action_sequence` or `send_keys`, which the runner answers `not implemented` | testdriver gap |
| 4: `idle-detection-*-permissions-policy*` | Savoia times out with no result, Safari errors | not established; neither passes | open |
| 3: clipboard files where Safari's row is a crash | — | nothing to compare with | — |
| 4: `GUM-deny`, `MediaDevices-SecureContext`, `enumerateDevices-per-origin-ids`, `focus-…-target-frame-state-ignored` | Savoia passes more than Safari | Safari's own report says why for one: "Unable to set permission to denied for this test" — safaridriver cannot, the runner can | — |
| 2: `notifications/instance`, `getnotifications-across-processes` | both are harness errors, one row apart | notifications are not built (below) | recorded |
| `MediaStreamTrack-getCapabilities` | four `facingMode` subtests | the real camera of this Mac against CI's mock devices; reasoning | — |
| `reporting/geolocation-reporting` | Savoia times out, Safari errors | geolocation is not built (below) | recorded |
| 5 others: `clipboard-read-enabled-on-self-origin`, `enumerateDevices-with-navigation`, `focus-…-click-handler`, `picture-in-picture-report-only`, `payment-extension-allowed-…` | one subtest or a status | not established | open |

What the runs turned up that is in no test's assertion:

- **The bar outlived its page** — above; fixed.
- **`window.open` had no opener** — 47 files timed out on it; a script-opened window is now the view WebKit asked
  for ([links.md](links.md#a-second-window)).
- **A page that navigated while in element fullscreen lost its view.** WebKit took it out of fullscreen and left
  the `WKWebView` in no window: the tab went blank and the page reported `hidden`. It is WebKit and SwiftUI's
  `WebView` between them — it happens with Savoia's own fullscreen hold switched off. `BrowserTab.leaveElementFullscreen`
  now runs `document.exitFullscreen()` before a main-frame navigation is allowed, and the view comes home; asking
  the web view to close its media presentations did not help, and rebuilding the pane around the page trapped in
  `_WebKit_SwiftUI`.
- **`evaluate_javascript` was a user gesture** — a first run that polled pages with it had every page activated,
  and clipboard files passed and failed at random ([page-scripts.md](page-scripts.md)).

And about the stand itself: under `*.localhost` plain http is a secure context and every host is a site of its
own, so it runs on wpt's names from `/etc/hosts`; a display that goes to sleep hides every page, so the runner
holds it awake; windows that tests open are closed before the next test. The clipboard files write to the system
clipboard and the capture files use the real camera — `--no-testdriver` leaves both out. Content blocking is on
in the throwaway home, as it is in a fresh install. Parts of the baseline were run against Safari's run of
5 October and parts against the 6th.

## What a `WebPage` browser still cannot ask for

- **Geolocation.** Half of it is public now, and it is the wrong half. macOS 27 added
  `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedBy:)`, but that only *decides*: the position has
  to come from a provider the host installs, and on macOS the only way to install one is C SPI on the process pool
  (`WKContextGetGeolocationManager`, `WKGeolocationManagerSetProvider`, `WKGeolocationPositionCreate` — WebKit's
  exports carry nothing else about location). Measured with the permission half built (`e64dd24`, taken back out
  after it): the bar came up, "Allow" was saved, and the page got `TIMEOUT` — or, asked without a timeout, waited
  forever — while `locationd` logged nothing from Savoia or WebKit for the whole minute. With nothing answering the
  delegate WebKit refuses at once, which is kinder than an "Allow" that leads nowhere.

  What that attempt taught, for whoever builds the SPI half. The proxy stood in front of `WebPage`'s own
  `WKUIDelegateAdapter` on the `WKWebView` `WebViewResponder` finds, forwarding everything else through
  `forwardingTarget(for:)` — and that part worked: `confirm()` and the microphone bar still went through the
  adapter. The selector has to be built from its string: `#selector` of the `WK_SWIFT_ASYNC_NAME` overload is not
  what WebKit sends, so `responds(to:)` said yes and the method was never called. `uiDelegate` is `weak`, so a proxy
  nobody retains is gone the moment it is installed. And taking `SitePermission.location` back out meant deleting the
  dev database's one `location` row first: `sitePermissions` decodes the list whole, so one unknown case forgets
  every answer.
- **Notifications.** `Notification.requestPermission()` answers `denied` and no question appears — which is why
  Mattermost prompts in Safari and not here. WebKit asks only a private `WKUIDelegate` method,
  `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:`, and refuses when nothing implements it.
  Answering it is half: a granted page's `new Notification()` reaches the UI process and stops there until the app
  installs a notification provider through C SPI (`WKNotificationManagerSetProvider`). The feature flag
  `BuiltInNotificationsEnabled`, which looks like WebKit showing them itself, hands both halves to `webpushd`
  instead, and that daemon serves only Apple's own apps. Measured, with the traps (a user gesture is required;
  private profiles are refused before any delegate is asked), in
  [todo.md](todo.md#geolocation-and-notifications-webkits-c-api-one-header-for-both).
- **Web Push.** Closed, not merely undocumented: `webpushd` requires the private entitlement
  `com.apple.private.webkit.webpush` from every client.

Geolocation and notifications are the same trade: C functions `WebKit.framework` exports and the SDK does not
declare, which a bridging header can declare and any macOS update can change. That is the direction chosen — see
[todo.md](todo.md).

