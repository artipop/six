# Site permissions

What a page is allowed to do with the machine, and who does the asking. Two things live here: the devices a site can
ask for (camera, microphone, location, notifications) and the four dialogs a page can put up (`alert`, `confirm`, `prompt`, the
file picker). They share a file's worth of thinking because they share a cause — a web view left alone answers both
kinds of question by itself, and both of its answers are wrong for a browser. Both are methods of a tab's UI
delegate, `PageDelegate`. The motion sensors were a third device while a tab was SwiftUI's `WebPage`; `WKUIDelegate`
has that question on iOS only, so on the Mac `SitePermission.motion` is never asked.

## The default Savoia replaced

A `WKUIDelegate` that does not answer the media-capture question gets `WKPermissionDecision.prompt`. That is not "nothing
works": WebKit puts up a permission popover of its own, the user answers it, and `getUserMedia()` resolves. Camera and
microphone worked in Savoia before any of this existed.

What the default cannot do is *remember*. Nothing is written down, so the same site asks on every load, and there is
nowhere to go and take an answer back. That is the whole reason `SitePermissions` exists: deciding the request
ourselves is what buys the memory and the undo, and the bar under the window's title bar is what it costs.

The dialogs are the harsher default. With no delegate method for them, all four return "no" —
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

What `WKWebView` leaves out is that sharing is *happening*: it publishes `cameraCaptureState` and
`microphoneCaptureState` and nothing public for the screen. `DisplayCapture` reads it from the tab's view as the view
is made: `_displayCaptureState` is SPI but KVO-compliant, and
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
answer about every site unreadable. Since `location` the list is decoded leniently (`Lenient` in
`SitePermissions.swift`): an answer this build cannot read costs only itself.

## Geolocation

WebKit splits it in two, and only one half is public. The question is `WKUIDelegate`'s
`webView(_:requestGeolocationPermissionFor:initiatedBy:)` (macOS 27), which `PageDelegate` answers from
`SitePermissions` like the camera's — `SitePermission.location`, the same bar, the same switch in the panel. The
position is the app's to supply, through C functions `WebKit.framework` exports and the SDK does not declare:
`Geolocation` (`Savoia/Browser/Geolocation.swift`) installs a `WKGeolocationProviderV1` on the process pool's
geolocation manager and feeds it from a `CLLocationManager` of its own. The declarations are in
`Savoia/Savoia-Bridging-Header.h`, copied from WebKit's open headers; the struct's layout is the contract, and one
that no longer matched would be a crash and not a compile error. All of it is `#if os(macOS)` — WebKitGTK has API of
its own for this.

What was not known before it was built, and is now measured:

- **A `WKContextRef` is the `WKProcessPool` object.** On Apple's ports WebKit's C types are its Objective-C
  wrappers, so the pointer is cast and nothing is looked up. The pool is read with KVC from the configuration a tab
  is built on (`configuration.processPool` is deprecated for *making* pools), and the provider is installed once per
  pool.
- **A request made while another is being served waits for the next position.** With a `watchPosition` running,
  `getCurrentPosition` with the default `maximumAge` of 0 is not given the position WebKit already holds and the
  provider is not asked again: a provider that reported once left it waiting forever — which is every map with a
  "my location" button on a Mac that is not moving. So while any page watches, `Geolocation` repeats what it knows
  once a second.
- **The async delegate method is called.** `e64dd24` found that `#selector` of the `WK_SWIFT_ASYNC_NAME` overload was
  not what WebKit sends; that was a proxy answering `responds(to:)` by hand. Implemented as the protocol's own
  method on `PageDelegate` it is found.

macOS asks too, once for the app (`NSLocationWhenInUseUsageDescription`), and here its prompt comes **after**
Savoia's bar: CoreLocation is started when WebKit asks the provider for a position, which is after the site was
allowed. A Mac with Location Services off for Savoia answers the page `POSITION_UNAVAILABLE`.

Not done: taking the answer back in the site menu does not stop a `watchPosition` already running — the provider
serves the pool, not a page, and the page keeps its watch until it reloads.

Under `SAVOIA_TESTDRIVER` CoreLocation is never started: `testdriver_set_geolocation` sets the position pages are
given, and with none set the position cannot be found — a test must not learn where it runs.

## Compatibility: web-platform-tests

`scripts/permissions-wpt.py` runs twelve wpt directories — `permissions`, `permissions-request`,
`permissions-revoke`, `permissions-policy`, `mediacapture-streams`, `screen-capture`, `mediacapture-handle`,
`geolocation`, `notifications`, `clipboard-apis`, `storage-access-api`, `idle-detection` — in a Debug Savoia it
launches itself in a throwaway home, and compares every file with one stable Safari run on wpt.fyi: the run the
baseline names (`safari.run` in the JSON). The bar is Safari's result for the same file, not the absolute number: a
failure Safari shares is WebKit's. It prints the Safari version of the run beside the system's, since they differ
(27.0 on wpt.fyi against 27.2 here). testdriver is carried the way wptrunner carries it to Safari
([test-suites.md](test-suites.md#what-unlocks-most-of-the-rest-testdriver)).

Since 8 October 2026 the same directories also run under wpt's own runner, `scripts/wpt.py`, against the same
pinned Safari run and with a baseline of its own, `scripts/wpt-baseline.json`: 338 of the 356 files give this
runner's result, 6 a better one, and the 12 that differ are listed with their causes in
[test-suites.md](test-suites.md#the-wpt-stand). The numbers below are this runner's.

**The run is pinned because Safari moves between its own runs.** `--newest-safari` compares with the newest one
and prints what moved in Safari apart from what moved in Savoia; `--safari-run <id>` names one; either with
`--write-baseline` re-pins, and every row of the baseline is then restamped with that run, the rows of directories
not run too. The pinned run is 5 October 2026 (wpt.fyi run `5068288941096960`, wpt `564b9b1eb1`) and not the one
after it: on 6 October nineteen of these files timed out in Safari that had finished the day before — eight in
`storage-access-api`, seven in `clipboard-apis`, four in `screen-capture` — and a timeout is nothing to compare with.

On wpt `1d99362`, 6 October 2026, baseline in `scripts/permissions-wpt-baseline.json`, one full run: 377 addresses,
21 left out, 356 run, **331 the same as Safari, 25 not** — and, since geolocation was built a day later, 315 and 41:
its sixteen files that were a harness error in both now run in Savoia and are still an error in Safari. Notifications
and `navigator.permissions` a day after that moved nineteen more the same way ([below](#notifications-in-the-suite)).

| directory | run | same | differ |
|---|---|---|---|
| `permissions`, `-request`, `-revoke` | 22 | 17 | 5 |
| `permissions-policy` | 117 | 105 | 12 |
| `mediacapture-streams` | 52 | 47 | 5 |
| `mediacapture-handle` | 1 | 1 | 0 |
| `geolocation` | 22 | 6 | 16 |
| `notifications` | 29 | 15 | 14 |
| `clipboard-apis` | 61 | 57 | 4 |
| `storage-access-api` | 40 | 40 | 0 |
| `idle-detection` | 12 | 8 | 4 |

The 21 left out call `getDisplayMedia()` — all of `screen-capture` and six files of `mediacapture-streams`. The
system's sharing picker waits for a person, the page needs focus, and Savoia is not in front during a run; with
`--screen` they run, for whoever will sit and answer.

The 25 of the full run, by cause (geolocation's sixteen are [below](#geolocation-in-the-suite)):

| files | what differs | why | state |
|---|---|---|---|
| 6: `permissions-policy/payment-*` (5), `reporting/payment-reporting` | Safari passes the "allowed" cases | `PaymentRequest` and `ApplePaySession` are `undefined` in Savoia, as in a bare `WKWebView`: WebKit keeps them from an app's view unless it sets an SPI switch ([tasks/browser/32](tasks/browser/32-apple-pay-switch.md)) | not supported |
| 4: `idle-detection-*-permissions-policy*` | Savoia times out with no result, Safari errors | not established; neither passes | open |
| 3: `async-unsanitized-standard-html-read-fail`, `clipboard-read-enabled-by-permissions-policy`, `readText-granted` | Safari's row is a crash | nothing to compare with | — |
| 4: `GUM-deny`, `MediaDevices-SecureContext`, `enumerateDevices-per-origin-ids`, `focus-…-target-frame-state-ignored` | Savoia passes more than Safari | Safari's own report says why for one: "Unable to set permission to denied for this test" — safaridriver cannot, the runner can | — |
| `MediaStreamTrack-getCapabilities` | four `facingMode` subtests | the real camera of this Mac against CI's mock devices; reasoning | — |
| `reporting/geolocation-reporting` | Savoia times out, Safari errors | the test waits for a violation report of `Permissions-Policy: geolocation=()`, and WebKit does not enforce the header ([below](#geolocation-in-the-suite)) | WebKit's |
| `focus-…-focused-frame-descendant` | one subtest, "B should be able to delegate focus to child C", fails | the stand, measured: the subtest reads `document.hasFocus()`, and the file gives Safari's 4/7 when Savoia is the active app and the page is the window's first responder, 3/7 behind another app — on the build before the key events too, so nothing here changed it. As launched by the runner the first responder is the window, not the page, and the app is not in front | the stand's; a run with Savoia in front would close it |
| 5 others: `clipboard-read-enabled-on-self-origin`, `enumerateDevices-with-navigation`, `focus-…-click-handler`, `picture-in-picture-report-only`, `payment-extension-allowed-…` | one subtest or a status | not established | open |

### Geolocation in the suite

Safari's row is no bar here: safaridriver cannot `set_permission` or stand a position in, so sixteen of its
twenty-two files are a harness error. The bar is the absolute number — **124 of 131 subtests, no file in harness
error**, where it was 94 with sixteen. The runner carries three things it used to refuse: `set_permission` for
`geolocation`, `bidi.permissions.set_permission` (the same answer under another action name), and
`bidi.emulation.set_geolocation_override` (`testdriver_set_geolocation`). A BiDi action names its browsing contexts
as `window` objects, which are not JSON; the runner's read of the page's queue failed on them silently until it
wrote them as a marker.

The seven that fail, all WebKit's:

| subtests | what | why |
|---|---|---|
| 2: `disabled-by-permissions-policy` (top-level), `enabled-on-self-origin-…` (cross-origin frame) | a page whose response says `Permissions-Policy: geolocation=()` is given a position | WebKit does not enforce the response header — measured here: the request reached the provider; and Safari fails `picture-in-picture-disabled-by-permissions-policy` 0/3 the same way. The `allow` attribute is enforced |
| 3: `getCurrentPosition-accuracyMode` (approximate), `-accuracyMode-cache` (both) | `accuracyMode` is ignored: the position is not coarsened, and a cached one is reused across modes | not implemented in WebKit; reasoning, from what the page was given |
| 2: `non-fully-active` | no error callback for a request on a detached frame's `navigator.geolocation` | WebKit calls nothing; the provider is never asked |

What closed the rest, October 2026:

- **Seven files that press keys** — `clipboard-copy-selection-line-break` (four addresses), `paste-on-detaching-iframe`,
  two `focus-without-user-activation-disabled-*` — give Safari's result since `send_keys` and `action_sequence` are
  real key events ([test-suites.md](test-suites.md#what-unlocks-most-of-the-rest-testdriver)).
- **Six files in `storage-access-api`** that were put down to a frame the runner could not find. Measured file by
  file, that was the cause of one:

  | file | what it was |
  |---|---|
  | `-cross-origin-iframe-navigation`, `-cross-site-sibling-iframes`, `-sandboxed-iframe-allow-storage-access`, `storage-access-permission` | every action succeeded and `requestStorageAccess()` still answered false or `NotAllowedError`: `set_permission` went to `_grantStorageAccessForTesting:`, which is not the permission. It goes to WebKit's automation call now |
  | `beyond-cookies.thirdPartyBlobStorage` | two actions named a frame inside a window the test opened; the runner searches those windows now |
  | `-web-socket` | no result at all: the stand had no `wss` port for `{{ports[wss][0]}}` and no `/echo-cookie` handler |

  All six give Safari's result. `prompt` and `denied` are no longer answered as done without doing anything: they
  go to the same call with `granted` false. That it takes a grant back was not measured apart from these files.
- **Eight in `storage-access-api` and two in `notifications`** were Safari's own run of 6 October; against the 5th
  they are the same.

`MediaDevices-getUserMedia` timed out once in the full run, in the audio `groupId` subtest, and has not since: ten
runs alone and two runs of the whole `mediacapture-streams` directory all give Safari's 3/8. The baseline holds
that; what the one timeout was is not established.

Two more of the same kind, 7 October 2026, in full runs after the baseline. `MediaStreamTrack-applyConstraints` timed
out once at its second subtest (1/17) and gave the baseline's 15/17 alone straight after. And
`MediaDevices-enumerateDevices-per-origin-ids` loses "stable deviceIds across same-origin iframe" whenever an iPhone
is in reach of this Mac: the page's list and its same-origin frame's were printed side by side, seven devices each,
and six carry the same `deviceId` in both — the one that does not is the Continuity Camera, «Камера (iPhone)», whose
id is another in every document and equal to its own `groupId`. That is WebKit's and the room's, not Savoia's; the
baseline's row was taken without the phone, and still stands.

What the runs turned up that is in no test's assertion:

- **The bar outlived its page** — above; fixed.
- **`window.open` had no opener** — 47 files timed out on it; a script-opened window is now a tab built on the
  configuration WebKit hands over ([links.md](links.md#a-second-window)).
- **A page that navigated while in element fullscreen lost its view.** WebKit took it out of fullscreen and left
  the `WKWebView` in no window: the tab went blank and the page reported `hidden`. That was SwiftUI's `WebView` and
  WebKit between them, and Savoia left fullscreen by script before a main-frame navigation to get round it. On a
  tab's own `WKWebView` the view comes home by itself — measured on the stand with a real click into fullscreen and
  a navigation out — and the workaround is gone.
  **Not always**, it turned out a day later: after `permissions-policy/reporting/fullscreen-report-only`, which sits
  in fullscreen until its timeout and is then navigated away, WebKit took its placeholder out of the tab's host
  (`completeFinishExitFullScreenAnimation`) and put no view back; the view was in no window, and every later click of
  a full run was refused as off screen — 22 of them, which cost `storage-access-api` 37 subtests. A page of the same
  shape made by hand did come home, and what the difference is was not found. `PageHost.Host` now takes the page
  back when a subview that is not the page leaves it empty and the page is out of fullscreen. Measured:
  `--only reporting/fullscreen --only storage-access-api` gives 40 of 40 with no click refused, where it gave the
  refusals before. It needs a visible page, so a run under a locked screen never showed it.
- **`evaluate_javascript` was a user gesture** — a first run that polled pages with it had every page activated,
  and clipboard files passed and failed at random ([page-scripts.md](page-scripts.md)).

And about the stand itself: under `*.localhost` plain http is a secure context and every host is a site of its
own, so it runs on wpt's names from `/etc/hosts`; a display that goes to sleep hides every page, so the runner
holds it awake; windows that tests open are closed before the next test. The clipboard files write to the system
clipboard and the capture files use the real camera — `--no-testdriver` leaves both out. Content blocking is on
in the throwaway home, as it is in a fresh install.

## Notifications

The same trade as [geolocation](#geolocation), with both halves private this time. The question is
`_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:`, which `PageDelegate` answers from
`SitePermissions` — `SitePermission.notifications`, the bar with a sentence of its own. What a granted page then
shows is the app's to draw: `SiteNotifications` (`Savoia/Browser/SiteNotifications.swift`) installs a
`WKNotificationProviderV0` on the process pool's notification manager, posts through `UserNotifications`, and tells
WebKit what became of each one — shown, clicked, closed — which is what a page hears as `onshow`, `onclick` and
`onclose`. The declarations are in the bridging header beside geolocation's, checked against WebKit's
`WKNotificationProvider.h`, `WKNotificationManager.h` and `WKNotification.h`; macOS only.

Measured in Savoia, under the test driver, 8 October 2026:

- **Without a user gesture `requestPermission()` is `denied` in 0 ms** and nothing reaches Savoia — WebCore refuses
  first. With a real click (`testdriver_click`) the bar comes up; answered Allow, the page gets `granted`.
- **`new Notification()` then fires `show`, and `close()` fires `close`** — the provider's two reports.
- **`Notification.permission` is `granted` after a reload**, and `navigator.permissions.query` agrees. WebKit keeps a
  list of its own for this, per origin, which it asks the provider for when a web process starts
  (`notificationPermissions`) and has to be told about afterwards
  (`WKNotificationManagerProviderDidUpdateNotificationPolicy`, `…DidRemoveNotificationPolicies`):
  `SitePermissions.onChanged` is that telling.

That list has no profile in it and Savoia's answers do. An origin allowed in any profile is `granted` in WebKit's
list; when a notification arrives, the tab it came from is found by its page and the answer of *that* profile is
asked again, so a profile that was told no shows nothing. A private profile is refused inside WebKit before anyone is
asked, as in Safari.

A click on the banner brings Savoia forward and selects the tab that showed it. A `tag` replaces the earlier
notification of the same site and tag. The system's own prompt, once for the app, comes with the first notification
and not with the first Allow.

**`navigator.permissions` answers from `SitePermissions` now**, for the camera, the microphone, location and
notifications: `_webView:queryPermission:forOrigin:completionHandler:`, which unanswered says `prompt` for
everything. And a `PermissionStatus` a page holds hears `change` when an answer is written or taken back —
`WKPagePermissionChanged`, the call WebKit's own test runner makes.

**A service worker's notifications** (`registration.showNotification`) go through a manager of their own, one for
the process (`WKNotificationManagerGetSharedServiceWorkerNotificationManager`), with no page. The provider is
installed there too. With no tab to ask, the profile is the one whose data store the notification names
(`WKNotificationCopyDataStoreIdentifier`; a profile's store is made from an identifier), and that profile's answer
decides. A click brings forward a tab of the site in that profile if there is one, and the worker hears
`notificationclick`; when it then calls `clients.openWindow`, WebKit asks the data store's delegate
(`_WKWebsiteDataStoreDelegate`, set on every profile's store by `SiteNotifications.store(for:)`) and gets a new tab
in that profile.

The icon (`WKNotificationCopyIconURL`) is downloaded by Savoia and attached to the banner, for a page's notification
and a worker's alike — with `URLSession`, not through the page, so a worker's `fetch` handler does not see the
request. Action buttons are not in WebKit at all.

Under `SAVOIA_TESTDRIVER` nothing is posted to the system: the provider reports "shown" at once, and a run leaves no
banners behind.

### Notifications in the suite

As with geolocation, Safari's row is no bar — safaridriver cannot `set_permission` — and the number is absolute:
**231 of 369 subtests, no file in harness error**, where it was 187 of 343 with sixteen — in a run that takes
`permissions` and `geolocation` first, which is how the baseline is written: two such runs on 7 October and one on
a quiet stand on 8 October. Run alone, the directory gives 221, three times out of three; the ten are one file (the
table). `permissions`, with its `-request` and `-revoke`, went from 150 of 206 to 175 of 234 on the same change: its
tests set `geolocation` and wait for `change`.

The stand resets between files now (`testdriver_reset`): answers about location and notifications, the stand-in
position, every notification shown. Without it one file's grant was the next file's starting state, and a test that
waits for a change from `prompt` waited forever.

What fails, by cause:

| subtests | what | why |
|---|---|---|
| 72: `idlharness` (four globals), 21: `lang` | the same as Safari | WebKit's: `actions`, `image`, `badge`, `vibrate`, `requireInteraction`, `maxActions`, no `Notification` in a shared worker, `lang` not validated |
| 6: `instance` | `requireInteraction` and `actions` are `undefined` | the same missing attributes |
| 10: `instance`, its service-worker half, **only when `notifications` is run alone** | "Service worker test setup" times out; after `permissions` and `geolocation`, or beside three neighbours, the file gives 28 of 34 | not established: it depends on what ran before, it is not the data store's delegate, and which file does it was not found ([unmeasured.md](unmeasured.md)). Where the ten pass it is by a coincidence — the `notificationclose` they wait for comes from a same-tagged notification, not from their own `close()` |
| 9: `shownotification` (6), `registration-association` (2), `getnotifications-across-processes` (1) | `getNotifications()` returns more than the test showed | WebKit refuses to `close()` a persistent notification younger than its minimum lifetime, so the tests' own cleanup does nothing. Measured both ways: no `cancel` reaches the provider for them, and with the lifetime set to 0 (`_WKWebsiteDataStoreConfiguration.overridePersistentNotificationMinimumLifetimeForTesting`) `shownotification` alone is 11 of 11. The override is not in the stand: in a full run it held for the first files and not the later ones, and the count came out lower (218) than without it |
| 5: `cross-origin-nested` (4), `cross-origin-serviceworker` (1), both tentative | a third-party frame or worker is `granted` | WebKit decides by the frame's own origin; the tests want a partitioned frame refused, as Firefox and Chrome do |
| 1: `event-onclose`, immediate close | no `close` for a notification closed before it was shown | read from WebCore: `close()` in the idle state stops the icon's loader and reports nothing |
| 1: `icon-fetch`, tentative | no fetch event for the icon | under the test driver nothing is posted and no icon is fetched; outside it Savoia fetches the icon itself, past the worker |

## What Savoia still cannot ask for

- **Web Push.** Closed, not merely undocumented: `webpushd` requires the private entitlement
  `com.apple.private.webkit.webpush` from every client.

## Geolocation and notifications: WebKit's C API, one header for both

Geolocation and notifications are shaped the same way: WebKit asks the app for permission through a delegate, then
expects the app to *supply* the thing — a position, a banner — through C functions that `WebKit.framework` exports
and the SDK does not declare. [Geolocation](#geolocation) and [notifications](#notifications) are built on them.

The direction chosen (Artem, 2026-09-15) is to declare them, in a bridging header copied from WebKit's open-source
`WKGeolocationManager.h`, `WKNotificationManager.h` and `WKNotificationProvider.h`. The alternative weighed was a
JavaScript stand-in for `Notification` installed at document start: public API only, but an imitation, and no answer
for service-worker notifications.

What the two share, built once:

- **The header**, `Savoia/Savoia-Bridging-Header.h`. The functions — `WKContextGetGeolocationManager`,
  `WKGeolocationManagerSetProvider`, `WKGeolocationManagerProviderDidChangePosition`, `WKGeolocationPositionCreate`;
  `WKContextGetNotificationManager`, `WKNotificationManagerSetProvider`, `WKNotificationManagerProviderDidShowNotification`,
  `…DidClickNotification`, `…DidCloseNotifications`, `WKNotificationCopyTitle`, `WKNotificationCopyBody`,
  `WKNotificationGetID` — are all in WebKit's exports on this macOS (`dyld_info -exports`). The provider structs are
  versioned (`WKGeolocationProviderV1`, `WKNotificationProviderV0`), and a layout that no longer matches is a crash
  rather than a compile error, so the header pins one version.
- **The `WKContextRef`.** Both managers hang off the process pool: `configuration.processPool` of a tab's
  `WKWebView`, and that object *is* the `WKContextRef` (`Geolocation.serve`).
- **The delegate.** Both permission questions are `WKUIDelegate` methods, and a tab's UI delegate is
  `PageDelegate`. A private one is declared there with `@objc(…)` and its selector written out, as the window-frame
  and context-menu methods are.

**Notifications**, before they were built — measured on 2026-09-15 in a throwaway app:

- `Notification.requestPermission()` is refused inside WebCore, before anyone is asked, unless it runs in a user
  gesture and a secure context. A script run over `Savoia --mcp` is not a gesture, which is why an early check from Savoia
  read `denied` in 3 ms and proved nothing about the delegate.
- A non-persistent data store — what Savoia's private profiles use — is refused in `WebNotificationClient` before the
  delegate too (`sessionID().isEphemeral()`). Private profiles stay without notifications, as in Safari.
- With a persistent store, made the way Savoia makes its other profiles, and a real click, the private delegate method
  `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` was called, answered yes, and the page got
  `granted`. `new Notification()` then reached the UI process (`showNotification called` in the log) and went no
  further: no provider, no banner, no `onshow`.
- `BuiltInNotificationsEnabled`, the feature flag that looks like WebKit showing them itself, sends both permission and
  display to `webpushd` through the network process: `requestPermission failed: no active connection to webpushd`,
  refused in 0 ms, with the data store's `webPushMachServiceName` set.

**Web Push** is out of reach rather than undocumented: `webpushd` checks the private entitlement
`com.apple.private.webkit.webpush` before serving a client, and Apple does not hand it out.

Savoia is not sandboxed and not on the App Store, so undeclared API carries no review risk here — only the ordinary one,
that it changes in a macOS update.

