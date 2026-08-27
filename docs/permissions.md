# Site permissions

What a page is allowed to do with the machine, and who does the asking. Two things live here: the devices a site can
ask for (camera, microphone, motion sensors) and the four dialogs a page can put up (`alert`, `confirm`, `prompt`, the
file picker). They share a file's worth of thinking because they share a cause — a `WebPage` left alone answers both
kinds of question by itself, and both of its answers are wrong for a browser.

## The default six replaced

`WebPage.Configuration.deviceSensorAuthorization` defaults to `WKPermissionDecision.prompt`. That is not "nothing
works": WebKit puts up a permission popover of its own, the user answers it, and `getUserMedia()` resolves. Camera and
microphone worked in six before any of this existed.

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
escapes the problem behind [`HostedOverlay`](../six/Views/HostedOverlay.swift): SwiftUI drawn over a `WKWebView` never
sees the mouse, and a permission bar whose buttons cannot be clicked is worse than no bar.

While the bar is up the page's `getUserMedia()` is suspended inside the decision closure. So a question that can never
be answered has to be answered anyway: closing the window, or giving its page back to the live-page budget, resolves
every question queued for it with a no (`SitePermissions.forget(_:)`, called from `BrowserTab.discard()` and
`close()`). A promise that never lands is a page that never finds out.

## In the title bar

- The **lock (or globe)** becomes a menu once the site has been answered about anything: flip an answer, forget the
  site's choices, or open the whole list. Sites with nothing decided keep a plain icon — a control that is always
  there and usually empty teaches people to ignore it.
- The **camera / microphone indicator** appears only while a device is actually in use, red while it is live. One
  click mutes, another lets the page see and hear again. Muted, not stopped: `setCameraCaptureState(.muted)` keeps the
  call up and tells the page it was muted, which is what the button in a call's own toolbar does. Blocking a device
  from the site menu *does* stop it (`.none`) — an answer that only applies to the next call is not an answer.

Both read `tab.livePage`, never `tab.page`. A title bar is drawn for every column in the strip, and reaching for the
page would build one for each of them just to ask whether the camera is on (see `BrowserTab.page`).

**Privacy → Site Permissions…** lists every site with a remembered answer, across profiles, with a switch per device
and an `×` that makes the site ask again.

## macOS is asking too

Granting here is not the end of it. The camera and the microphone are behind TCC, and the system's own prompt — the
one `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` fill in, in
[`InfoPlist.xcstrings`](../six/InfoPlist.xcstrings) — comes **first**, before six's bar, and comes once for the app
rather than once per site. Measured, not assumed: on the first `getUserMedia({audio: true})` of a fresh install the
system asks "Разрешить приложению «six» доступ к микрофону?", and only once that is answered does WebKit call the
decision closure and six's own bar appear. So the very first request a user ever makes costs two answers, and every
one after it costs at most one.

six is not sandboxed ([build.md](build.md)), so there are no `com.apple.security.device.*` entitlements in play; the
usage strings and a signed bundle are the whole requirement. If either string were missing the request would
be denied with no prompt at all, which is why they are there and why they are localized.

## What a `WebPage` browser still cannot ask for

- **Screen sharing** (`getDisplayMedia`). No public API. WebKit has it — `WKPreferences._screenCaptureEnabled` plus
  `_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:`, which returns
  `ScreenPrompt`/`WindowPrompt` and lets WebKit run its own picker — but both are SPI on `WKWebView`, and `WebPage`
  does not expose the `WKWebView` underneath.
- **Geolocation.** The public delegate method arrived in macOS 27
  (`WKUIDelegate.requestGeolocationPermissionForOrigin:`), which six targets — but it is a `WKUIDelegate` method, and
  `WebPage.DeviceSensorAuthorization.Permission` has only `mediaCapture` and `deviceOrientationAndMotion`. So
  `NSLocationWhenInUseUsageDescription` sits in the Info.plist with nothing wired to it yet.
- **Web Push.** SPI as well (`_getPendingPushMessages`, `_processPushMessage` on `WKWebsiteDataStore`), and a push
  daemon's worth of work beyond the call itself.

All three are the same trade rather than three different ones: they need `WKWebView` and a delegate, which means
giving up `WebPage` and the SwiftUI-native model six is built on. Worth doing when one of them is actually wanted;
not worth doing pre-emptively. See [todo.md](todo.md).
