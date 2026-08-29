# Linux — WebKitGTK

six on Linux is a third front end over the same storage layer, on WebKitGTK 6.0 and GTK 4 through
libadwaita. It is not a port of the SwiftUI views; it is a second front over the parts of six that
were never about Apple in the first place.

| | |
|---|---|
| engine | **WebKitGTK 6.0** (2.52.3), one `WebKitWebView` per column |
| toolkit | **libadwaita 1.9** through [adwaita-swift](https://codeberg.org/aparoksha/adwaita-swift) |
| language | **Swift 6.3**, the same source tree |
| storage | **the same `six.sqlite`**, the same schema, the same migrations |
| built in | a container ([build.md](build.md#linux)) |

The reason this is worth doing at all is the storage layer. `SixCore` — `NiriLayout`, `AppDatabase`,
`SettingsStore`, `HistoryStore`, `Bookmark`, `AppSupport` — imports Foundation and Observation and
nothing else, and builds on Linux unchanged. A database written by the Mac opens here, migrates
forward, and reads back. That was the premise ([storage.md](storage.md)) and it held.

## Two packages, and why

`Package.swift` at the root declares `SixCore` and the tests. It reads the same files where they lie
— `path: "six"` plus an explicit `sources:` list — so nothing moves, `six.xcodeproj` is not edited,
and a file joins a module by being listed rather than by being relocated. That is the same shape the
iOS target already had, where membership is an exception list in the project file.

`linux/Package.swift` is separate because SwiftPM cannot leave a target out per platform, and a
`pkgConfig: "webkitgtk-6.0"` target cannot resolve on a machine with no webkitgtk. Keeping it apart
is what lets the root package still build on a Mac.

```
six-linux ── SixUI ── SixWebKit ── SixWebKitCore ── CWebKitGTK
                 └─── SixBrowser ── SixCore
```

- **`CWebKitGTK`** — `systemLibrary`, one header. GTK itself comes from adwaita's own `CAdw`; webkit's
  headers pull in the same gtk headers and Clang unifies them.
- **`SixWebKitCore`** — the interop, and no toolkit at all: `NetworkSession`, `PageRegistry`,
  `Thumbnails`, `PermissionRequests`, `Signal`. This is the part that stays whichever UI library wins.
- **`SixWebKit`** — the page as a widget adwaita can place.
- **`SixBrowser`** — the model. **Deliberately without Adwaita**, and the compiler enforces it: adwaita
  depends on its own vendored SQLite (`meta-sqlite` → `CSQLite`) while `SixCore` reaches GRDB's, and
  Clang refuses two definitions of `sqlite3_api_routines` in one compilation unit. So the seam the
  plan asked for is not a matter of discipline; it fails to build if crossed.
- **`SixUI`** — the only module that knows what a toolkit is.

adwaita-swift is pinned to a commit, not a tag: its only tag, `0.1.0`, does not build on Linux
(their #97), and the maintainer's advice is to live on `main`.

`Package.resolved` is **seeded from the app's own** and `swift package update` is a Linux-breaking
command here — see the comment at the top of `Package.swift` for the three reasons.

## What is built

- The strip: `NiriLayout` shared with the Mac, columns along it and workspaces across, ⌥←/⌥→,
  ⌥↑/⌥↓, ⌥R for the width preset, ⌥O for the overview.
- The overview is one `GskTransform` on a `GtkFixed` child, not a second layout — the same idea as
  the Mac's, which is that the overview is a way of *looking* at the strip.
- Pages: navigation, address bar, back/forward/reload, the live-page budget
  ([architecture.md](architecture.md)), thumbnails for discarded columns.
- History and bookmarks, in the shared tables, scoped per profile.
- Private browsing as a profile with an ephemeral `WebKitNetworkSession`.
- Site permissions for the camera and the microphone ([permissions.md](permissions.md)).
- The strip comes back after a relaunch, out of the `settings` table.

## What is not

- **Extensions.** WebKitGTK 2.52 parses a manifest and no more: `WebKitWebExtension` reads
  `manifest.json`, permissions and icons, but `WebExtensionContext` and `WebExtensionController` —
  the classes that actually run one — are not exposed yet. Igalia is porting them from Apple's
  Objective-C to C++ shared by all ports. See [extensions.md](extensions.md) for the reversal this
  implies: on Linux six owns a real `WebKitWebView` per column, which is the single reason content
  scripts are half-deaf on macOS.
- **Blocking.** `WebKitUserContentFilterStore` eats the same content-blocker JSON as
  `WKContentRuleList`, so this is wiring rather than design ([blocking.md](blocking.md)).
- **Embeddings and vector search.** MLX is Metal; out of scope for this phase by decision.
- **The assistant, ACP and MCP.** `six/ACP/` and `six/MCP/` are the most portable code in the
  repository — Foundation, child processes, JSON-RPC over stdio — and would fit Linux better than
  iOS, where they were excluded for the lack of `Process`. Not wired to a front yet.
- **Sync.** There is none anywhere.

## Three things GTK does differently, and one of them is a trap

**A `Task` never runs.** Under `g_main_loop_run` the thread belongs to GLib, and nothing drains
Swift's main-actor executor — a `Task` created from a signal handler simply does not execute. This
is why `SitePermissions.decide` is a callback function with the `async` one layered on top rather
than the other way round. Anything asynchronous on this front has to be driven by GLib, not by Swift
concurrency.

**Every signal has its own C signature, and getting it wrong is silent.** adwaita's
`SignalData.HandlerType` exists precisely because GObject hands a handler a different argument list
per signal: `notify::` is `.oneArg`, `load-changed` is `.guint`. Taking the `.noArgs` default for
`load-changed` produced a null dereference inside adwaita's own signal machinery, three renders in
and nowhere near the mistake. Where no case fits — `permission-request` returns `gboolean` *and*
takes an argument — the trampoline is written out by hand next to the signal, and `Signal` in
`SixWebKitCore` owns the boxing, the `GClosureNotify` and the connect so that trio exists once.

**Only value types live in `@State`.** Meta reflects over a view's stored properties to find its
state, and a class in one takes the runtime down inside `swift_getTypeByMangledName` — the window
comes up, draws once and dies. The model is `BrowserModel.shared`. State is also *seeded* rather than
filled from `onAppear`: an assignment made while a view is appearing has nowhere to land, because the
body was already evaluated with the old value.

## Running it

| | |
|---|---|
| `SIX_URL` | space-separated addresses to open on a first launch |
| `SIX_WIDTH` | index into `NiriLayout.widthPresets` |
| `SIX_LIVE_PAGES` | pin the live-page budget, for measuring |
| `SIX_UI_DEBUG=1` | what the model was asked to do and what it thought it was doing |
| `SIX_MOCK_CAPTURE=1` | a camera and a microphone that are not there, for testing permissions |

## Where it is behind the Mac

- **The strip clamps at its ends.** `resolvedOffset` centres the focused column, and the Mac places
  columns absolutely in a container that does not scroll, so the first and last columns centre like
  any other. Here the strip is a real `GtkScrolledWindow` and its adjustment clamps, so the outermost
  columns sit against the edge instead of centred.
- **No page-level scripting.** `PageScripts` and `PageControllers` are not wired yet, which is what
  highlights, the readable copy and the DevTools capture are built on. WebKitGTK's
  `call_async_javascript_function` takes the same body, arguments and world name as
  `callJavaScript(_:arguments:contentWorld:)` — and, unlike Apple's, it awaits a returned Promise, so
  this is one of the places Linux ends up ahead rather than behind.
- **Localization** is English only: `String(localized:)` is Apple Foundation's, and a GTK front
  localises through gettext. Where a shared file needed a string, the Linux branch spells the key.
