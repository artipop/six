# API watch

What Savoia is waiting on Apple for: every place Savoia either lacks a feature or reaches past the public SDK, the exact
name to look for when it becomes public, and what to delete in Savoia when it does. Check it on every new SDK — a
macOS beta, an Xcode or Command Line Tools update, a Safari Technology Preview release note.

The target builds against the active Xcode's own SDK (`SDKROOT = macosx`; see [build.md](build.md#sdk)), so that
is the SDK to read.

## The list

| capability | today in Savoia | watch for | when it lands |
|---|---|---|---|
| **Geolocation** | not built; a site is refused at once ([permissions.md](permissions.md#what-savoia-still-cannot-ask-for)) | a public position provider on macOS — today only C SPI `WKGeolocationManagerSetProvider` / `WKGeolocationPositionCreate` (`Source/WebKit/UIProcess/API/C/WKGeolocationManager.h`); or WebKit using CoreLocation itself for third-party apps. The permission hook is already public: `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedBy:)`, macOS 27 | build the permission half again from `e64dd24`, on the public provider |
| **Site notifications** | not built; `requestPermission()` answers `denied` ([todo.md](permissions.md#geolocation-and-notifications-webkits-c-api-one-header-for-both)) | a public `WKUIDelegate` method for notification permission — today `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` in `WKUIDelegatePrivate.h`; a public provider — today `WKNotificationManagerSetProvider` (`WKNotificationProvider.h`, `WKNotificationProviderV0`); or `BuiltInNotificationsEnabled` working without `webpushd`'s entitlement | skip the bridging-header plan in todo.md |
| **Web Push** | out of reach | `com.apple.private.webkit.webpush` offered to third parties, or a public `WKWebsiteDataStore` push API (today `_getPendingPushMessages`, `_processPushMessage`) | new work, nothing to delete |
| **Screen-sharing state** | SPI in use: `_displayCaptureState` (KVO) and `_setDisplayCaptureState:completionHandler:` — `Savoia/Browser/DisplayCapture.swift` | a public `displayCaptureState` next to `cameraCaptureState` on `WKWebView` | delete `DisplayCapture.swift`, read the property like the camera's |
| **Picture-in-picture** | SPI in use: `_setAllowsPictureInPictureMediaPlayback:`, `_isPictureInPictureActive` — `Savoia/Browser/PagePictureInPicture.swift` | `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` declared for macOS (today iOS only); a public "is in picture-in-picture" | drop the SPI half of that file |
| **`declarativeNetRequest.onRuleMatchedDebug`** | not implemented by WebKit | the event implemented | nothing — it is WebKit's gap, not Savoia's |
| **`browser.idle`, `bookmarks`, `browsingData`, `runtime.onEnabled`, `storage.setAccessLevel`** | absent in WebKit; Savoia scores what Safari scores on wpt `web-extensions/` ([extensions.md](extensions.md#compatibility-web-platform-tests)) | `NEW PASS` from `scripts/web-extensions-wpt.py` after a system update; for bookmarks, `bookmarksForExtensionContext:` and its siblings leaving `WKWebExtensionControllerDelegatePrivate.h` | bookmarks answered from `BookmarkStore`; the rest is a new baseline |
| **Extension testing mode** | SPI in use, only under `SAVOIA_EXTENSION_TESTING`: `_testingMode` and the `recordTest…` delegate methods — `Savoia/Extensions/ExtensionTesting.swift` | a public testing switch on `WKWebExtensionController` | the SPI goes |
| **Opening Web Inspector** | Safari can attach. SPI opens it on a tab — `_inspector`, with `developerExtrasEnabled` — measured, not built ([tasks/devtools/22](tasks/devtools/22-web-inspector-in-savoia.md)) | any public API beyond `isInspectable` | the SPI goes |
| **Automation of a tab** | not turned on. `_WKAutomationSession` answers in-process for a view made `_controlledByAutomation`, and a tab's configuration is Savoia's to set now. Decided against ([tasks/agents/15](tasks/agents/15-agent-tools-to-chrome.md)): a page reads the flag as `navigator.webdriver` (measured), and by itself it drives nothing | a public flag on `WKWebViewConfiguration` and a public session | an agent's tools over WebKit's own automation |
| **A script that is not a user gesture** | SPI in use: `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:` — `BrowserTab.callWithoutGesture` ([page-scripts.md](page-scripts.md)) | a gesture flag on `WKWebView.callAsyncJavaScript` | the SPI goes |
| **What is under the pointer, for the context menu** | SPI in use: `_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:` and `_WKContextMenuElementInfo.hitTestResult.absoluteLinkURL` — `PageDelegate`; without it WebKit's own menu shows | a public delegate method that hands over the element | the SPI goes |
| **The motion sensors' question** | none on macOS: `requestDeviceOrientationAndMotionPermissionFor` is iOS only, and `SitePermission.motion` is never asked | the method declared for macOS | route it into `SitePermissions` as on iOS |
| **A count of find matches** | none: `WKWebView.find` says only whether there is one | `_countStringMatches:options:maxCount:` made public, or a count on `WKFindResult` | "2 of 5" in the find bar |
| **Apple Pay for pages** | `PaymentRequest` is `undefined`, cause not established ([todo.md](tasks/browser/11-page-scripts-rest.md)) | — | — |

## What stopped being a wait

Until October 2026 a tab was SwiftUI's `WebPage`, and eight rows here waited for it to hand out its `WKWebView`, take
a `WKWebViewConfiguration`, answer a new-window request, or carry `interactionState` and `createWebArchiveData`. A tab
is a `WKWebView` of Savoia's own now ([architecture.md](architecture.md#from-webpage-to-wkwebview)), so those are
built and their rows are gone: the view-tree walk, extension pages as tabs, web archives, the session state before a
tab is shown, a window a page opens as a tab with its opener, and both fullscreen workarounds. `WebPage` itself is no
longer worth watching for Savoia's sake.

## Where changes show up

- **Apple's documentation, with API changes shown.** Every page on developer.apple.com/documentation has an
  "API Changes" switch that marks what an SDK added, deprecated or changed. Open `WKUIDelegate`, `WKWebView`,
  `WKWebViewConfiguration`, `WKWebExtensionContext` with it on after each beta.
- **Release notes.** Safari release notes carry WebKit's changes (`developer.apple.com/documentation/safari-release-notes`),
  along with the macOS and Xcode release notes on the same site. New WebKit API usually appears first in a
  Safari Technology Preview, announced on the WebKit blog (`webkit.org/blog`).
- **WebKit's own source.** A method becomes public by moving from a `…Private.h` header to its public sibling in
  `Source/WebKit/UIProcess/API/Cocoa/` (for example from `WKUIDelegatePrivate.h` to `WKUIDelegate.h`), with a
  `WK_API_AVAILABLE` naming the release. The history of those files on github.com/WebKit/WebKit shows it before an
  SDK ships.
- **Asking.** The requests worth filing are already named in [todo.md](todo.md): Feedback Assistant for Apple, and
  bugs.webkit.org for WebKit.

## Checking a new SDK

The quickest check is the SDK's headers:

```sh
SDK=$(xcrun --show-sdk-path)                                    # the one Savoia builds with
H=$SDK/System/Library/Frameworks/WebKit.framework/Headers

grep -rn -i "displayCaptureState\|allowsPictureInPictureMediaPlayback\|requiredWebExtensionBaseURL\|NotificationPermission\|Geolocation" "$H"
grep -rn -i "contextMenu\|callAsyncJavaScript\|DeviceOrientationAndMotion\|controlledByAutomation" "$H"
```

What the running OS actually implements, whatever the headers say, is in the runtime; the probes used for this list
listed selectors with `class_copyMethodList` and exports with `dyld_info -exports
/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit`. A name in the exports but not in the headers is
still SPI.
