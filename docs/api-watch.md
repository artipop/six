# API watch

What Savoia is waiting on Apple for: every place Savoia either lacks a feature or reaches past the public SDK, the exact
name to look for when it becomes public, and what to delete in Savoia when it does. Check it on every new SDK — a
macOS beta, an Xcode or Command Line Tools update, a Safari Technology Preview release note.

The target builds against the active Xcode's own SDK (`SDKROOT = macosx`; see [build.md](build.md#sdk)), so that
is the SDK to read.

## The list

| capability | today in Savoia | watch for | when it lands |
|---|---|---|---|
| **Geolocation** | not built; a site is refused at once ([permissions.md](permissions.md#what-a-webpage-browser-still-cannot-ask-for)) | a public position provider on macOS — today only C SPI `WKGeolocationManagerSetProvider` / `WKGeolocationPositionCreate` (`Source/WebKit/UIProcess/API/C/WKGeolocationManager.h`); or WebKit using CoreLocation itself for third-party apps; or a geolocation case in `WebPage.DeviceSensorAuthorization.Permission`. The permission hook is already public: `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedBy:)`, macOS 27 | build the permission half again from `e64dd24`, on the public provider |
| **Site notifications** | not built; `requestPermission()` answers `denied` ([todo.md](todo.md#geolocation-and-notifications-webkits-c-api-one-header-for-both)) | a public `WKUIDelegate` method for notification permission — today `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` in `WKUIDelegatePrivate.h`; a public provider — today `WKNotificationManagerSetProvider` (`WKNotificationProvider.h`, `WKNotificationProviderV0`); or `BuiltInNotificationsEnabled` working without `webpushd`'s entitlement | skip the bridging-header plan in todo.md |
| **Web Push** | out of reach | `com.apple.private.webkit.webpush` offered to third parties, or a public `WKWebsiteDataStore` push API (today `_getPendingPushMessages`, `_processPushMessage`) | new work, nothing to delete |
| **Screen-sharing state** | SPI in use: `_displayCaptureState` (KVO) and `_setDisplayCaptureState:completionHandler:` — `Savoia/Browser/DisplayCapture.swift` | a public `displayCaptureState` next to `cameraCaptureState` on `WKWebView`, or on `WebPage` | delete `DisplayCapture.swift`, read the property like the camera's |
| **Picture-in-picture** | SPI in use: `_setAllowsPictureInPictureMediaPlayback:`, `_isPictureInPictureActive` — `Savoia/Browser/PagePictureInPicture.swift` | `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` declared for macOS (today iOS only), or a field on `WebPage.Configuration`; a public "is in picture-in-picture" | drop the SPI half of that file |
| **The web view behind a `WebPage`** | view-tree walk — `Savoia/Input/WebViewResponder.swift`; used by extensions, screen sharing, picture-in-picture and fullscreen | `WebPage` handing out its `WKWebView`, or a way to associate a `WebPage` with a `WKWebExtensionTab` | the walk stays for the keyboard; the other callers read the property |
| **The web view behind a `WebPage`, from the start** | not available before a pane shows the tab | `WebPage.backingWebView` — `@_spi(CrossImportOverlay) public` on WebKit's `main`, not among macOS 27.2's exports | the view-tree walk goes, and with it "only while on screen" |
| **Extension pages as columns** | open in a window of their own — `ExtensionStore.openExtensionPage` | `WebPage.Configuration` taking a `WKWebViewConfiguration` (so `WKWebExtensionContext.webViewConfiguration` can be used), or a public `requiredWebExtensionBaseURL` (today SPI `_setRequiredWebExtensionBaseURL:` on `WKWebViewConfiguration`) | open them as ordinary columns; the new-tab override starts working (it hits the same -1008 today) |
| **`declarativeNetRequest.onRuleMatchedDebug`** | not implemented by WebKit | the event implemented | nothing — it is WebKit's gap, not Savoia's |
| **`browser.idle`, `bookmarks`, `browsingData`, `runtime.onEnabled`, `storage.setAccessLevel`** | absent in WebKit; Savoia scores what Safari scores on wpt `web-extensions/` ([extensions.md](extensions.md#compatibility-web-platform-tests)) | `NEW PASS` from `scripts/web-extensions-wpt.py` after a system update; for bookmarks, `bookmarksForExtensionContext:` and its siblings leaving `WKWebExtensionControllerDelegatePrivate.h` | bookmarks answered from `BookmarkStore`; the rest is a new baseline |
| **Extension testing mode** | SPI in use, only under `SAVOIA_EXTENSION_TESTING`: `_testingMode` and the `recordTest…` delegate methods — `Savoia/Extensions/ExtensionTesting.swift` | a public testing switch on `WKWebExtensionController` | the SPI goes |
| **Opening Web Inspector** | Safari can attach. SPI opens it on a tab — `_inspector`, with `developerExtrasEnabled` — measured, not built ([tasks/devtools/22](tasks/devtools/22-web-inspector-in-savoia.md)) | any public API beyond `isInspectable` | the SPI goes |
| **Automation of a tab** | none: `_WKAutomationSession` answers in-process, but only for a view made `_controlledByAutomation`, which `WebPage`'s is not ([tasks/agents/15](tasks/agents/15-agent-tools-to-chrome.md)) | the flag on `WebPage.Configuration` made public — it is there as `@_spi(Testing) isControlledByAutomation`, exported by macOS 27.2's WebKit and absent from the SDK's interface | an agent's tools over WebKit's own automation |
| **Web archives** | Save As has `.html`, `.pdf`, `.txt` | `createWebArchiveData` on `WebPage` | `.webarchive` in Save As |
| **Back-forward state across launches** | `interactionState` taken from and given to the `WKWebView` a pane mounts (`WebViewResponder`), addresses otherwise | `interactionState` on `WebPage` | restore a tab before it is shown, and drop the address lists |
| **A script that is not a user gesture** | SPI in use: `_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:` — `BrowserTab.callWithoutGesture` ([page-scripts.md](page-scripts.md)) | a gesture flag on `WebPage.callJavaScript` or `WKWebView.callAsyncJavaScript` | the SPI goes |
| **A window a page opens** | a delegate in front of `WebPage`'s own answers `createWebView` with a bare `WKWebView` in an `NSWindow` — `Savoia/Browser/ScriptedPopups.swift` | `WebPage` answering new-window requests, or an initialiser from a `WKWebViewConfiguration`. Nothing public on when: the question sits unanswered on Apple's forum since January 2026 ([814318](https://developer.apple.com/forums/thread/814318)), beside one about `javaScriptCanOpenWindowsAutomatically` missing from `WebPage` ([803351](https://developer.apple.com/forums/thread/803351)); a quick search of bugs.webkit.org in October 2026 found no bug | script-opened windows become ordinary tabs, and the unsized ones keep their opener ([links.md](links.md#a-second-window)) |
| **A count of find matches** | none: `WKWebView.find` says only whether there is one | `_countStringMatches:options:maxCount:` made public, or a count on `WKFindResult` | "2 of 5" in the find bar |
| **Apple Pay for pages** | `PaymentRequest` is `undefined`, cause not established ([todo.md](todo.md#apple-pay-not-supported-and-why-is-not-known)) | — | — |
| **A page leaving element fullscreen by navigating** | Savoia exits fullscreen first — `BrowserTab.leaveElementFullscreen`; otherwise the web view is left in no window | the bug fixed; retest with the call removed | delete the call |
| **Element fullscreen in SwiftUI's `WebView`** | black without the temporary hold — `Savoia/Browser/PageElementFullscreen.swift` | the bug fixed (forums thread 720612); retest with the hold removed | delete the hold |

## Where changes show up

- **Apple's documentation, with API changes shown.** Every page on developer.apple.com/documentation has an
  "API Changes" switch that marks what an SDK added, deprecated or changed. Open `WKUIDelegate`, `WKWebView`,
  `WKWebViewConfiguration`, `WebPage`, `WebPage.Configuration`, `WKWebExtensionContext` with it on after each beta.
- **Release notes.** Safari release notes carry WebKit's changes (`developer.apple.com/documentation/safari-release-notes`),
  along with the macOS and Xcode release notes on the same site. New WebKit API usually appears first in a
  Safari Technology Preview, announced on the WebKit blog (`webkit.org/blog`).
- **`WebPage`'s own source**: `Source/WebKit/UIProcess/API/Swift/` on github.com/WebKit/WebKit — `WebPage.swift`
  and `WebPage+Configuration.swift`. An `@_spi` there is in the binary before it is in any SDK, and
  `dyld_info -exports … | grep WebPage | xcrun swift-demangle` says whether this macOS has it.
- **WebKit's own source.** A method becomes public by moving from a `…Private.h` header to its public sibling in
  `Source/WebKit/UIProcess/API/Cocoa/` (for example from `WKUIDelegatePrivate.h` to `WKUIDelegate.h`), with a
  `WK_API_AVAILABLE` naming the release. The history of those files on github.com/WebKit/WebKit shows it before an
  SDK ships.
- **Asking.** The requests worth filing are already named in [todo.md](todo.md): Feedback Assistant for Apple, and
  bugs.webkit.org for WebKit — nothing there yet mentions `WKWebExtension` together with `WebPage`.

## Checking a new SDK

The quickest check is the SDK itself, header and Swift interface both:

```sh
SDK=$(xcrun --show-sdk-path)                                    # the one Savoia builds with
H=$SDK/System/Library/Frameworks/WebKit.framework/Headers
I=$SDK/System/Library/Frameworks/WebKit.framework/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface

grep -rn -i "displayCaptureState\|allowsPictureInPictureMediaPlayback\|requiredWebExtensionBaseURL\|NotificationPermission\|Geolocation" "$H"
grep -n "struct Configuration" -A40 "$I" | grep "public var"          # WebPage.Configuration's fields
grep -n -i "backingWebView\|WKWebView\|geolocation\|notification\|webArchive\|interactionState" "$I"
```

What the running OS actually implements, whatever the headers say, is in the runtime; the probes used for this list
listed selectors with `class_copyMethodList` and exports with `dyld_info -exports
/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit`. A name in the exports but not in the headers is
still SPI.
