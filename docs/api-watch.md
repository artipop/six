# API watch

What six is waiting on Apple for: every place six either lacks a feature or reaches past the public SDK, the exact
name to look for when it becomes public, and what to delete in six when it does. Check it on every new SDK — a
macOS beta, an Xcode or Command Line Tools update, a Safari Technology Preview release note.

The target builds against the **Command Line Tools** SDK (`SDKROOT` in the project; see [build.md](build.md)), so
that is the SDK to read, not Xcode's.

## The list

| capability | today in six | watch for | when it lands |
|---|---|---|---|
| **Geolocation** | not built; a site is refused at once ([permissions.md](permissions.md#what-a-webpage-browser-still-cannot-ask-for)) | a public position provider on macOS — today only C SPI `WKGeolocationManagerSetProvider` / `WKGeolocationPositionCreate` (`Source/WebKit/UIProcess/API/C/WKGeolocationManager.h`); or WebKit using CoreLocation itself for third-party apps; or a geolocation case in `WebPage.DeviceSensorAuthorization.Permission`. The permission hook is already public: `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedBy:)`, macOS 27 | build the permission half again from `e64dd24`, on the public provider |
| **Site notifications** | not built; `requestPermission()` answers `denied` ([todo.md](todo.md#geolocation-and-notifications-webkits-c-api-one-header-for-both)) | a public `WKUIDelegate` method for notification permission — today `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:` in `WKUIDelegatePrivate.h`; a public provider — today `WKNotificationManagerSetProvider` (`WKNotificationProvider.h`, `WKNotificationProviderV0`); or `BuiltInNotificationsEnabled` working without `webpushd`'s entitlement | skip the bridging-header plan in todo.md |
| **Web Push** | out of reach | `com.apple.private.webkit.webpush` offered to third parties, or a public `WKWebsiteDataStore` push API (today `_getPendingPushMessages`, `_processPushMessage`) | new work, nothing to delete |
| **Screen-sharing state** | SPI in use: `_displayCaptureState` (KVO) and `_setDisplayCaptureState:completionHandler:` — `six/Browser/DisplayCapture.swift` | a public `displayCaptureState` next to `cameraCaptureState` on `WKWebView`, or on `WebPage` | delete `DisplayCapture.swift`, read the property like the camera's |
| **Picture-in-picture** | SPI in use: `_setAllowsPictureInPictureMediaPlayback:`, `_isPictureInPictureActive` — `six/Browser/PagePictureInPicture.swift` | `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` declared for macOS (today iOS only), or a field on `WebPage.Configuration`; a public "is in picture-in-picture" | drop the SPI half of that file |
| **The web view behind a `WebPage`** | view-tree walk — `six/Input/WebViewResponder.swift`; used by extensions, screen sharing, picture-in-picture and fullscreen | `WebPage` handing out its `WKWebView`, or a way to associate a `WebPage` with a `WKWebExtensionTab` | the walk stays for the keyboard; the other callers read the property |
| **Extension pages as columns** | open in a window of their own — `ExtensionStore.openExtensionPage` | `WebPage.Configuration` taking a `WKWebViewConfiguration` (so `WKWebExtensionContext.webViewConfiguration` can be used), or a public `requiredWebExtensionBaseURL` (today SPI `_setRequiredWebExtensionBaseURL:` on `WKWebViewConfiguration`) | open them as ordinary columns; the new-tab override starts working (it hits the same -1008 today) |
| **Extensions on iOS** | switched off | `webView(for:)` answerable on iOS — the same `WebPage` accessor as above | turn `ExtensionStore` back on for the phone |
| **`declarativeNetRequest.onRuleMatchedDebug`** | not implemented by WebKit | the event implemented | nothing — it is WebKit's gap, not six's |
| **Opening Web Inspector** | Safari can attach; six cannot open it ([devtools.md](devtools.md)) | any public API beyond `isInspectable` | an inspector in six's own window |
| **Web archives** | Save As has `.html`, `.pdf`, `.txt` | `createWebArchiveData` on `WebPage` | `.webarchive` in Save As |
| **Back-forward state across launches** | trail restored as addresses | `interactionState` (a `WKWebView` property since macOS 12) on `WebPage` | restore scroll and form state |
| **Element fullscreen in SwiftUI's `WebView`** | black without the temporary hold — `six/Browser/PageElementFullscreen.swift` | the bug fixed (forums thread 720612); retest with the hold removed | delete the hold |

## Where changes show up

- **Apple's documentation, with API changes shown.** Every page on developer.apple.com/documentation has an
  "API Changes" switch that marks what an SDK added, deprecated or changed. Open `WKUIDelegate`, `WKWebView`,
  `WKWebViewConfiguration`, `WebPage`, `WebPage.Configuration`, `WKWebExtensionContext` with it on after each beta.
- **Release notes.** Safari release notes carry WebKit's changes (`developer.apple.com/documentation/safari-release-notes`),
  along with the macOS and Xcode release notes on the same site. New WebKit API usually appears first in a
  Safari Technology Preview, announced on the WebKit blog (`webkit.org/blog`).
- **WebKit's own source.** A method becomes public by moving from a `…Private.h` header to its public sibling in
  `Source/WebKit/UIProcess/API/Cocoa/` (for example from `WKUIDelegatePrivate.h` to `WKUIDelegate.h`), with a
  `WK_API_AVAILABLE` naming the release. The history of those files on github.com/WebKit/WebKit shows it before an
  SDK ships.
- **Asking.** The requests worth filing are already named in [todo.md](todo.md): Feedback Assistant for Apple, and
  bugs.webkit.org for WebKit — nothing there yet mentions `WKWebExtension` together with `WebPage`.

## Checking a new SDK

The quickest check is the SDK itself, header and Swift interface both:

```sh
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk     # the one six builds with
H=$SDK/System/Library/Frameworks/WebKit.framework/Headers
I=$SDK/System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/Modules/WebKit.swiftmodule/arm64e-apple-macos.swiftinterface

grep -rn -i "displayCaptureState\|allowsPictureInPictureMediaPlayback\|requiredWebExtensionBaseURL\|NotificationPermission\|Geolocation" "$H"
grep -n "struct Configuration" -A40 "$I" | grep "public var"          # WebPage.Configuration's fields
grep -n -i "backingWebView\|WKWebView\|geolocation\|notification\|webArchive\|interactionState" "$I"
```

What the running OS actually implements, whatever the headers say, is in the runtime; the probes used for this list
listed selectors with `class_copyMethodList` and exports with `dyld_info -exports
/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit`. A name in the exports but not in the headers is
still SPI.
