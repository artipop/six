# Upstream: bugs that are not six's

Three of them, kept here with the repro that isolates each. Two are Linux regressions that keep
SQLiteData from building; the third is a WebKit rendering bug that makes a video's own fullscreen
button draw a black screen under SwiftUI's `WebView`.

## The two Linux regressions

Found while bringing six's storage layer up on Linux ([docs/storage.md](docs/storage.md)). Neither is
six's bug and neither is in a package six imports — both arrive through `SQLiteData`, which depends on
`Sharing` unconditionally. Both are **regressions**: the immediately preceding release of each builds
clean on the same toolchain.

six works around them by seeding its `Package.resolved` from the app's own, which holds the graph at
the last good versions. That is a workaround, not a fix, and it makes `swift package update` a
Linux-breaking command in this repo — hence these two reports.

Environment for everything below:

```
Swift version 6.3.3 (swift-6.3.3-RELEASE)   Target: aarch64-unknown-linux-gnu
Ubuntu 24.04.4 LTS, aarch64
docker.io/library/swift:6.3.3-noble
```

---

## 1. pointfreeco/swift-sharing — 2.10.0 does not build on Linux

**Title:** `2.10.0 fails to build on Linux: no such module 'Foundation.NSData'`

### Summary

`swift-sharing` 2.10.0 does not compile on Linux. `Sources/Sharing/Internal/Deprecations.swift`
imports the `Foundation.NSData` *submodule*, which exists only where Foundation is a Clang module —
on Linux, Foundation is a Swift module and has no submodules, so the import fails outright.

2.9.1, 2.8.2 and 2.5.2 all build clean on the same toolchain, so this is a regression rather than a
platform limitation.

The repository's CI declares a Linux job on Swift 6.3
(`.github/workflows/ci.yml`, `linux: container: swift:${{ matrix.swift }}`, matrix `swift: ['6.3']`),
which suggests the job is not catching this.

### Steps to reproduce

```sh
docker run --rm swift:6.3.3-noble bash -c '
  git clone -q --depth 1 --branch 2.10.0 https://github.com/pointfreeco/swift-sharing /tmp/s
  cd /tmp/s && swift build'
```

### Actual

```
/tmp/s/Sources/Sharing/Internal/Deprecations.swift:2:18: error: no such module 'Foundation.NSData'
error: emit-module command failed with exit code 1
```

The source, unchanged on `main` at the time of writing:

```swift
// Sources/Sharing/Internal/Deprecations.swift
#if canImport(Foundation)
  package import Foundation.NSData
#endif
```

`canImport(Foundation)` is true on Linux, so the guard does not protect the submodule import — the
condition tests the wrong thing.

### Expected

Builds, as 2.9.1 does. Swapping the branch in the command above to `2.9.1`, `2.8.2` or `2.5.2` gives
`Build complete` with zero errors.

### Suggested fix

`import Foundation` rather than the submodule, or guard the submodule import on a Clang-module
Foundation (`#if canImport(Darwin)`) instead of on `canImport(Foundation)`.

---

## 2. pointfreeco/combine-schedulers — 1.2.1 does not build on Linux

**Title:** `1.2.1 fails to build on Linux under Swift 6.3: missing import of CoreFoundation`

### Summary

`Sources/CombineSchedulers/Internal/Lock.swift` uses `pthread_mutex_t` and `pthread_mutexattr_t` in
the non-Darwin branch under a bare `import Foundation`. Swift 6.3's `MemberImportVisibility` rejects
that: the types come from `CoreFoundation`, which the file never imports.

1.2.0 builds clean on the same toolchain, so this is a regression.

Two things make it awkward downstream: the diagnostic is an *error* rather than a warning because the
package selects its own Swift language mode, so neither `-Xswiftc -Wwarning -Xswiftc
MemberImportVisibility` nor `-Xswiftc -swift-version -Xswiftc 5` on the consumer's command line
reaches it.

### Steps to reproduce

```sh
docker run --rm swift:6.3.3-noble bash -c '
  git clone -q --depth 1 --branch 1.2.1 https://github.com/pointfreeco/combine-schedulers /tmp/c
  cd /tmp/c && swift build'
```

### Actual

Six errors, the first being:

```
/tmp/c/Sources/CombineSchedulers/Internal/Lock.swift:53:19: error: initializer 'init()' is not
available due to missing import of defining module 'CoreFoundation' [#MemberImportVisibility]

51 |     init() {
52 |       var attr = pthread_mutexattr_t()
53 |       var mutex = pthread_mutex_t()
   |                   `- error: ...
```

### Expected

Builds, as 1.2.0 does.

### Suggested fix

One line, in the `#else` branch that already exists:

```diff
 #else
+  import CoreFoundation
   import Foundation
```

Confirmed: applying exactly this to the checkout clears all six errors, and the build then proceeds
past the package.

---

## What this costs downstream

`SQLiteData` depends on `Sharing` unconditionally (target dependency, not trait-gated), so any package
that uses SQLiteData on Linux resolves into both of these. six uses none of the layer that pulls
`Sharing` in — no `@FetchAll`, no `@Fetch`, no `@Shared`, only `@Table`, `#sql` and `defaultDatabase` —
and still cannot build without pinning around them.

Unrelated but worth knowing for anyone else arriving here:
[sqlite-data#459](https://github.com/pointfreeco/sqlite-data/pull/459) is an open Linux-support PR for
SQLiteData itself, covering CloudKit gating in its tests and its GRDB floor. It does not touch either
of the packages above, so merging it would not by itself make SQLiteData build on Linux.

---

## 3. WebKit — element fullscreen draws nothing under SwiftUI's `WebView`

**Title:** `WebView` with `webViewElementFullscreenBehavior(.enabled)` goes fullscreen and renders a
black screen; the same page in a `WKWebView` is correct

### Summary

On macOS 27, a page taken fullscreen from a SwiftUI `WebView` shows nothing at all. WebKit does
everything it says it does — `WebPage.fullscreenState` walks `enteringFullscreen` → `inFullscreen`, a
`WebCoreFullScreenWindow` opens at the size of the display, the web view is moved into it, audio goes
on playing and the media controls' timer goes on advancing — and the window draws its backdrop. `⎋`
gives the page back unharmed, which is what makes it read as a lost tab rather than a lost frame.

The same URL, the same machine, in a `WKWebView` behind an `NSViewRepresentable` with
`configuration.preferences.isElementFullscreenEnabled = true`, is perfect. The difference between the
two is how the view is held. SwiftUI's `WebView` hosts it under Auto Layout —
`translatesAutoresizingMaskIntoConstraints == false`, `autoresizingMask` empty. WebKit's fullscreen
controller moves the view into a window of its own and sizes it by frame; a view that answers to
constraints arrives there with none of them, is laid out at nothing, and the window has only its
backdrop to show. A `WKWebView` held that way has been going black in fullscreen since at least 2022
— [developer.apple.com/forums/thread/720612](https://developer.apple.com/forums/thread/720612) — where
the answer is the same two lines as the workaround below. What is new is that SwiftUI's own wrapper
now puts every `WebView` in that state, with no public way to say otherwise.

### Steps to reproduce

Twenty-five lines, no third-party code:

```swift
import SwiftUI
import WebKit

@MainActor enum Holder { static let page = WebPage() }

struct Root: View {
    var body: some View {
        WebView(Holder.page)
            .webViewElementFullscreenBehavior(.enabled)
            .onAppear {
                let url = URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!
                _ = Holder.page.load(URLRequest(url: url))
            }
    }
}

struct FSTest: App {
    var body: some Scene { WindowGroup { Root() } }
}

FSTest.main()
```

Build against the macOS 27 SDK, run, and press the fullscreen button in the video's controls.

**Expected:** the video, full screen.
**Actual:** a black screen at the size of the display. The sound plays and the timer advances. `⎋`
returns to a page that is entirely fine.

For the control, replace the `WebView` with an `NSViewRepresentable` around a `WKWebView` configured
with `preferences.isElementFullscreenEnabled = true`: fullscreen is correct.

### Environment

```
macOS 27.0 (Darwin 27.0.0), Apple silicon
Command Line Tools macOS 27.0 SDK
Swift 6.4
```

### Workaround

Reach the `WKWebView` behind the `WebPage` and let it answer to its frame while WebKit has it:

```swift
view.translatesAutoresizingMaskIntoConstraints = true
view.autoresizingMask = [.width, .height]
```

Only for the duration. Left on, SwiftUI goes on laying the surrounding view out with constraints the
view no longer answers to. six does this from `enteringFullscreen` until the state comes back to
`notInFullscreen` (`six/Browser/PageElementFullscreen.swift`), and the web view itself is reached
through `Mirror`, because `WebPage` does not hand it out — which is to say the workaround is only
available to someone willing to do both of those things.

