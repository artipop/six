# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting. The engine is real
WebKit — the WebKit2 C API, the same family WebKitGTK's C API descends from — linked against the
actual Playwright-built `WebKit2.dll` that `../sixty`'s MiniBrowserSwift prototype already proved
out. A page loads, navigates, reports its title back, renders inside its own card at the display's
real resolution, and answers a click where the click looks like it landed. Where the Mac reaches for the top bar and the assistant
panel, this front draws the rail, an address bar and nothing past it.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting for the chrome — no WinUI, no XAML |
| engine | **real WebKit** (WebKit2 C API), software compositing — see "DPI and scale" |
| language | Swift, the same source tree — and now the same `SixCore`, not a subset of it |
| storage | the graph is up (GRDB, SQLiteData, a real SQLite round-trip); the rail itself does not persist yet |
| built with | `6.3.3+NoAsserts`, and that is not a preference — see below |
| built in | on the Windows dev machine directly — `scripts/six-windows.ps1` |
| verified | **yes** — built, run, every rail mechanic and real page loads exercised by hand |

## Why Win32 and not WinUI 3

A rougher prototype of this front already exists in a sibling checkout, `../sixty`, and it went the
other way: `swift-winrt`-generated bindings over the Windows App SDK, a real `Window`/`Grid`/`Button`
tree, a working `HelloWindow`. It is real progress and the more native-looking path long term. It
also needs, before six's own first line compiles: NuGet-fetched Windows App SDK packages, a
`projections.json`-driven codegen step, and the maintainers' own notes that the generated bindings
are slow to regenerate and easy to dirty in Debug. None of that is something `swift build` alone gets
through.

`WinSDK` is different: it ships with the toolchain. `import WinSDK` and `RegisterClassExW` /
`CreateWindowExW` / a `GetMessage` loop are there with nothing fetched and nothing generated. That is
the bar "the build should also pass on Windows" sets, and it is a bar plain Win32 clears today while
the WinUI path does not yet. The two are not in tension — `sixty`'s WinRT projection is a plausible
future replacement for `SixUI`'s own chrome rendering once it needs a native look, and nothing here
forecloses it: `RailModel` does not know GDI exists, the way `linux/`'s `BrowserModel` does not know
GTK exists.

## Why WebKit2 and not WebView2

The obvious pragmatic choice for a Windows engine is `WebView2` (Chromium/Edge) — Microsoft's own
embedding API, well documented, no exotic build needed. It was tried first, briefly: the SDK
downloads as a plain NuGet package and the headers extract cleanly. It was dropped without writing
any integration code, on a direct steer — six is a WebKit browser on every other front, and matching
engines matters more here than matching platform convention. `../sixty/windows/WebKitAdapter`
already had the harder problem (a real WebKit build that runs on Windows at all) solved, via the
Playwright-shipped WebKit binary; using it is the smaller task.

## Why the `+NoAsserts` toolchain

`windows/Package.swift` depends on the root package the way `linux/Package.swift` does, and that is
newer than this front is. Its first version had **no package dependencies at all** and took
`NiriLayout.swift`, `KeyBindings.swift` and `KeyContext.swift` out of `six/` through symlinks in a
`SixCoreShared` target instead, because depending on `SixCore` pulls in `SQLiteData` → GRDB →
`swift-structured-queries`, and that package would not compile here. On both official Windows
toolchains it was tried against — the `0.0.0+Asserts` nightly and `6.3.3-RELEASE` — its keyPath
dynamic-member-lookup subscripts (`Type.self[keyPath: keyPath]`, the mechanism its whole "type-safe
query building" API is built on, used ~85 times across the package) crashed `swift-frontend`:

```
Assertion failed: (path.size() == 1 && path[0].getKind() == ConstraintLocator::SubscriptMember) ||
  (path.size() == 2 && path[1].getKind() == ConstraintLocator::KeyPathDynamicMember),
  file …\swift\lib\Sema\CSSimplify.cpp, line 16426
```

That was read as a Windows compiler bug — [swiftlang/swift#69386](https://github.com/swiftlang/swift/issues/69386),
open since October 2023 — and the whole `SixCoreShared` arrangement was built to route around it.

**It is not a Windows bug. It is an assertions bug, and Windows is the only platform where
swift.org ships an assertions-enabled toolchain.** The tell was there all along in the message: an
`Assertion failed` exists only in a compiler built without `NDEBUG`. The same assertion fires on
**macOS** with an open-source toolchain — [swiftlang/swift#82529](https://github.com/swiftlang/swift/issues/82529),
same file, same predicate, same package — and six's own Mac and Linux builds compile this code every
day because Xcode's compiler and swift.org's Linux toolchains are release builds. Every official
Windows toolchain installs as `<version>+Asserts`, so the platform that looked cursed was only the
platform that ships the debug compiler.

The fix is a toolchain, not a patch. swift.org's Windows installer **already carries** the release
compiler — its bundle manifest declares `OptionsIncludeNoAsserts = 1` and holds `bld.noasserts.msi`
and `cli.noasserts.msi` beside the asserts ones — it just does not install it by default:

```powershell
swift-6.3.3-RELEASE-windows10.exe OptionsInstallNoAssertsToolchain=1
```

It lands at `%LOCALAPPDATA%\Programs\Swift\Toolchains\6.3.3+NoAsserts`, beside `+Asserts` rather
than over it, and shares the already-installed SDK and runtime. `scripts/six-windows.ps1` defaults
to it and says this if it is missing. Nothing else about the graph changes: same pins as every other
front, GRDB 7.11.1 / sqlite-data 1.11.0 / structured-queries 0.37.0.

Measured on this machine, all four with the same source and the same SDK:

| | `6.3.3+Asserts` | `6.3.3+NoAsserts` |
|---|---|---|
| `swift-structured-queries` 0.37.0 alone | crash, four sites | builds, 79 s |
| `sqlite-data` 1.11.0, `@Table` + `#sql` + `.where {}.select()` | never reached | builds and round-trips real SQLite |
| `SixCore` | never reached | builds, 0 errors |
| the front | never reached | builds |

`-c release` does not help, and neither does a newer `swift-structured-queries`: the pattern is
unchanged on its `main`.

### The two things that still need doing by hand

**SQLite.** Windows has no system SQLite — no `sqlite3.h`, no import library — so GRDB's
`GRDBSQLite` system-library target has nothing to resolve against and the build dies on
`'sqlite3.h' file not found` before any Swift is reached. This is the same gap the Linux container
fills with `libsqlite3-dev`. `six-windows.ps1` fetches the amalgamation into
`%LOCALAPPDATA%\six-tools`, compiles it once with `cl`, and puts the directory on `INCLUDE` and
`LIB` — which is how a dependency's own modulemap, one this build never sees, finds the header. The
defines are not free choices: GRDB declares `SQLITE_ENABLE_SNAPSHOT` and `SQLITE_ENABLE_FTS5` as
Swift flags everywhere but Linux, so its source calls those APIs and the library has to have them.

**`combine-schedulers`.** It arrives through `SQLiteData` → `Sharing` → `swift-dependencies`, and no
released version of it compiles here: its non-Darwin lock assumes `import Foundation` brings
`pthread_mutex_t` along, true on Linux and false on Windows. Not a regression — a gap that was never
filled; [UPSTREAM.md](../UPSTREAM.md) section 4 is the report. The fix is twenty lines of `SRWLOCK`,
kept as `windows/patches/combine-schedulers-1.2.0-srwlock.patch`. `six-windows.ps1` clones the
package as a **sibling of the repository**, applies the patch, moves the `1.2.0` tag onto the result
and points SwiftPM's mirror mechanism at it — a sibling and not a copy inside the repo, so it stays
a real checkout that a remote can be added to and the patch sent upstream. `mirrors.json` is
generated rather than committed because SwiftPM will only take an absolute path for a mirror.

Disabling the `CombineSchedulers` trait in `swift-dependencies` does not avoid this: `swift-sharing`
depends on the package directly as well, and traits union across a graph.

## DPI and scale

At this dev machine's 150% display scale, a live column used to draw its page 1.5x too large,
spilling past its own `HWND`, with the part that landed outside the card receiving no mouse input at
all. It is fixed by a window procedure in front of the `WKView`
(`RailWebView.installScaleShim`) — **load-bearing; do not "clean up" it or the divided rect
`WebEngine.makeView` hands to `WKViewCreate` without re-reading this.**

**It is not a WebKit bug. Playwright deletes one line, and this is that line.** Their patch set is
public — `browser_patches/webkit/patches/bootstrap.diff` in `microsoft/playwright` — and in
`Source/WebKit/UIProcess/win/WebView.cpp`, `WebView::onSizeEvent`, it does this:

```diff
-    m_viewSize = expandedIntSize(FloatSize(LOWORD(lParam), HIWORD(lParam)) / intrinsicDeviceScaleFactor);
+    m_viewSize = expandedIntSize(FloatSize(LOWORD(lParam), HIWORD(lParam)));
```

Upstream takes `WM_SIZE`'s physical dimensions and divides them by the device scale, so `m_viewSize`
is logical. Playwright keeps them physical — reasonable for headless automation, where a screenshot
should come out the size you asked for, and wrong for anything drawing into a real scaled window.

Everything observed follows from that one line. WebKit renders at `viewSize × deviceScaleFactor` and
presents the result into the window one backing pixel to one; upstream that is
`(physical / scale) × scale = physical`, exactly the window. With the division gone it is
`physical × scale`, so at 150% a 1390-pixel-wide window gets a 2085-pixel surface — 1.5x too large,
spilling out of its own `HWND`. Measured before any of this was known: a page writing
`innerWidth`/`devicePixelRatio` into its own title reported `iw=1390 dpr=1.5` against a `WKView`
`HWND` that `GetWindowRect` confirmed was exactly 1390 wide.

It also explains why nothing reachable through the C API moved it. The damage is done at the source
of `m_viewSize`, before any of `WKPageSetCustomBackingScaleFactor`, the process DPI mode, or the
units of the creation rect get a say.

**The fix is that same division, done from outside the process.** Subclass the `WKView`'s `HWND` and
divide `WM_SIZE`'s dimensions by the display scale before passing the message on — which is
literally the deleted line, reimplemented one stack frame earlier. WebKit then believes its client area is 926 wide, renders
`926 × 1.5 = 1389` pixels, and blits that into the 1390-pixel window it actually has: correct size,
and rendered at the display's real resolution rather than upscaled from 96 DPI. The view is created
at the divided rect too, so that the `setFrame` which immediately follows in
`RailLiveView.updateLiveView` is the `WM_SIZE` that puts it through the shim. `main.swift` stays
`DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, so the rail's own GDI chrome is unaffected.

This is exactly what Windows' own `DPI_HOSTING_BEHAVIOR_MIXED` does — and mixed hosting then gives
the benefit straight back by bitmap-scaling the child's output, which is the thing being avoided.
(Mixed hosting does work, incidentally, and it took a while to find out: `SetThreadDpiHostingBehavior`
has to be in effect when the *parent* is created, not around `WKViewCreate`. With it, the view's
backing scale really does come back as 1.0.)

**Mouse messages are deliberately not rewritten**, which is the counter-intuitive half — and which
the patch also explains, since it leaves the event path alone. WebKit already divides an event's
client coordinates by the device scale, and that is exactly the factor between where a CSS pixel is
drawn and where it is — so the shim's first version, which divided them
too, moved every click by 1.5x again: clicking the middle cell of a labelled grid reported the cell
two along. With `WM_SIZE` alone, a click at the visual centre of that cell reports that cell, at CSS
coordinates within two pixels of its centre.

**What was tried and does not work**, each measured rather than reasoned about:

| tried | result |
|---|---|
| `WKPageSetCustomBackingScaleFactor(page, 1.0)` | the page then reports `dpr=1` and the raster is unchanged, before and after a forced resize — it moves what the page reports, not what is drawn |
| `DPI_AWARENESS_CONTEXT_SYSTEM_AWARE` for the process | system DPI *is* 144 on this machine; no change |
| `DPI_AWARENESS_CONTEXT_UNAWARE_GDISCALED` for the process | correct geometry and clicks, and this shipped for a while — but the whole page is then upscaled from 96 DPI by the compositor, which is visibly soft |
| `SetThreadDpiAwarenessContext(UNAWARE)` around `WKViewCreate` alone | nothing changes — mixed hosting has to be enabled before the *parent* is created |
| creating the `WKView` with the rect divided by the scale and then resizing it to full size | no difference; that resize is what the shim is now there to intercept |
| `WKViewSetUsesOffscreenRendering(view, true)` | shrinks into a corner, rest blank |
| page zoom | scales what is drawn and what is hit-tested by the same factor, so it cannot close a gap between them |
| sizing the live view to 1/1.5 of its card and leaving it there | sharp and correctly sized, and the right and bottom thirds of the page stop receiving mouse input |
| Playwright's newest WebKit — `webkit-2360`, one revision past the pinned `webkit-2359`, from `https://cdn.playwright.dev/dbazure/download/playwright/builds/webkit/<rev>/webkit-win64.zip` (`2361`+ are 400, so that is the newest that exists) | identical, and now expected: every Playwright build carries the patch above. Only a non-Playwright build drops the shim — [todo.md](todo.md) |

**Accelerated compositing is off** (`WKPreferencesSetAcceleratedCompositingEnabled(preferences,
false)`). With the shim in place the accelerated path draws correctly too — it was the DPI-unaware
approach it could not survive — but it put a visible layer seam through the middle of a search
field. Worth revisiting; not worth shipping.

## Where things are

```
windows/Package.swift              Depends on the root package by path (named `six` explicitly:
                                    a path dependency takes its identity from the directory, and
                                    this checkout is `six-main`), on sqlite-data, and on
                                    combine-schedulers only to hold it at the version the mirror
                                    carries. The `SixCoreShared` symlink target it used to carry is
                                    gone — see above.

windows/patches                    combine-schedulers-1.2.0-srwlock.patch: the twenty lines that
                                    make that package compile on Windows, applied to a sibling
                                    clone by the build script and ready to send upstream.

windows/.swiftpm/configuration     Generated, and gitignored: SwiftPM will only take an absolute
                                    path for a mirror, so this file names one machine's checkout.

windows/Sources/CRailInterop       <windowsx.h>'s mouse/wheel macros, the WM_NCCREATE / GWLP_USERDATA
                                    dance a WNDPROC needs, and the cursor/key-state helpers that
                                    dodge two ClangImporter rough edges — all inline C, so the C
                                    compiler checks the types instead of Swift re-deriving macros.

windows/Sources/CWebKit2           The WebKit2 C API headers, copied unmodified from
                                    ../sixty/windows/WebKitAdapter/Sources/CWebKit2 — whoever built
                                    the matching WebKit2.dll adapted them to keep <windows.h> types
                                    off the C boundary (a Clang-modules submodule-visibility issue
                                    under ClangImporter), using layout-compatible plain structs and
                                    `void *` instead, cast back to HWND at the Swift call site.
                                    Header-only; shim.c exists only because SwiftPM wants a
                                    translation unit.

windows/vendor/WebKit2             WebKit2.lib/.def/.exp — the import library generated from the
                                    engine DLL's own export table, because the DLL ships without an
                                    MSVC-compatible one. Not the DLL itself, which is large and
                                    already on the machine — see "Building and running". Regenerate
                                    it when a build moves its exports (1677 of them in webkit-2359,
                                    so do not assume the .def survives a revision):

                                        dumpbin /exports WebKit2.dll > exports_raw.txt
                                        # write a .def with an EXPORTS section, one symbol per line
                                        lib /def:WebKit2.def /out:WebKit2.lib /machine:x64

windows/Sources/SixBrowser         RailModel: NiriLayout plus the tab metadata every column needs and
                                    the URL a live one is at — no toolkit and no WebKit2 in it.
                                    RailKeyLookup: the same move for KeyBindings/KeyContext. Both
                                    `@testable import SixCoreShared`, the seam
                                    linux/Sources/SixBrowser already uses on SixCore.

windows/Sources/SixUI              RailWindow (the Win32 window, message dispatch), RailRendering
                                    (GDI painting and the geometry everything else borrows back),
                                    RailInput (mouse and wheel), RailKeyInput (WM_KEYDOWN /
                                    WM_SYSKEYDOWN), WebEngine + RailWebView (the WebKit2 wrapper),
                                    RailLiveView (positions the focused column's WKView over its
                                    card's body), AddressBar (a plain Win32 EDIT control).

windows/Sources/six-windows        main.swift: declare DPI awareness, create the window, pump
                                    messages, done.

scripts/six-windows.ps1            Build (and optionally run) it.
```

## Building and running

```powershell
./scripts/six-windows.ps1 build   # compile, copy the runtime DLLs next to the .exe
./scripts/six-windows.ps1 run     # stop what is running, build, launch exactly one
./scripts/six-windows.ps1 stop    # stop what is running, nothing else
```

All three are idempotent — `run` twice leaves one window, not two, and none of them care what was
running first.

The script exists because a plain `swift build` in `windows/` needs three things arranged around it
that cost real time to work out, and are worth never re-deriving:

1. **The MSVC linker on `PATH`.** `vcvars64.bat`'s environment has to be imported into the current
   process; the script does this itself rather than requiring a "Developer PowerShell" session.
2. **The Swift toolchain's own `bin` directories on `PATH`.** Not automatic even once installed, and
   it must be the `+NoAsserts` one — see "Why the `+NoAsserts` toolchain". The script defaults to it
   and, if it is not installed, says the single command that installs it.
4. **A SQLite, and a patched `combine-schedulers`.** Neither exists on a fresh Windows machine; the
   script fetches and builds both, once, and says where it put them. Same section.
3. **The runtime DLLs copied next to the built `.exe`.** None of the Universal CRT API-set DLLs, the
   Swift runtime DLLs, or the WebKit2 engine and its `WebKitWebProcess`/`WebKitNetworkProcess`/
   `WebKitGPUProcess` helper `.exe`s are guaranteed resolvable from a plain `CreateProcess` launch —
   a missing CRT one surfaces as `STATUS_DLL_NOT_FOUND` (`0xC0000135`) with no further detail,
   whether or not the same DLL is technically present somewhere under `C:\Windows\System32\downlevel\`
   or the Windows SDK's own `Redist\ucrt\DLLs\x64\`. Copying all three sets is the reliable fix,
   cheaper than diagnosing why a system-wide install did not put them on the loader's path. (A
   `Microsoft Visual C++ Redistributable (x64)` install is still worth having; it is just not
   sufficient on its own.) The engine is whatever `-WebKitDir` points at — any
   WebKit2.dll build whose exports still match `windows/vendor/WebKit2`'s import library. It
   defaults to the newest `%LOCALAPPDATA%\ms-playwright\webkit-*` only because that is the build
   already on this machine.

Two Win32 environment quirks worth knowing if this script is ever revisited:

- **Symlink creation needs Developer Mode**, a one-time Windows setting
  (`Settings → Privacy & security → For developers`), or every `git clone`/`swift package edit` of a
  dependency that itself uses symlinks fails outright with a permission error.
- **`SW_SHOWDEFAULT` silently does not show the window** when the process was started with
  redirected stdout/stderr, as any script capturing build output will do — it defers to the
  launching process's own `STARTUPINFO.wShowWindow`, which such a launch often leaves unset.
  `RailWindow.show()` uses `SW_SHOWNORMAL`, which shows the window unconditionally; the script
  launches the built `.exe` with `UseShellExecute = $true` for the same reason.

**A six-windows that has already stopped can go on holding this whole directory**: 0 threads, no
image path left, `taskkill` answering "Access is denied". It has no window and does nothing, but
Windows will not overwrite a file it still has mapped, so left alone it fails a build in two
different places — the linker on `six-windows.exe`, `Copy-Item` on `BlocksRuntime.dll`. The script
works around both rather than waiting them out: the old `.exe` is renamed aside (renaming works on a
mapped image where overwriting does not), and a locked DLL is left alone, since it is by definition
already present and is the same artefact the copy would have written — that is what the
`in use, keeping the copy already there` warnings are. The state clears on a reboot.

## Verified

Built and run for real on the Windows dev machine — every mechanic below exercised by hand and
confirmed working:

- The storage graph, before any of it was wired into the front: `swift-structured-queries` 0.37.0,
  `sqlite-data` 1.11.0 and GRDB 7.11.1 all compile under `+NoAsserts`, and a `@Table` type went
  through a `#sql` migration, two inserts, `.order(by:)`, `.where {}.select()` and back out of a
  real file on disk, twice, the second run reading what the first wrote. GRDB's own query interface
  was proved separately, without `swift-structured-queries` in the graph at all, in case the
  toolchain answer had not worked out.

- Open a column by clicking empty background; focus one by clicking it; close one by clicking its
  "×".
- Placeholder columns are each a distinct, stable colour, picked from the tab's own id so a column
  keeps its colour when the rail reorders it.
- `Alt` + mouse wheel steps a workspace (vertical) or a column (horizontal); `Shift` turns either
  into the "move it, don't just focus it" variant.
- `⌥←/→` (focus a column), `⌥⇧←/→` (reorder it), `⌥⇧↑/↓` (move it to the workspace above/below,
  confirmed by watching the workspace label change) all answer through the real `KeyBindings` table.
- The focused column's `WKView` loads its start page, navigates, reports its title back through
  `WKPageNavigationClientV3`'s `didFinishNavigation` into `RailModel.setTitle`, renders inside its
  own card, and hit-tests a click where the click looks like it landed — see "DPI and scale".
- `SIX_URL` overrides the start page, which is how a run gets pointed at a test page without a
  keyboard.
- The address bar shows the focused column's URL and repositions on resize. Typing a URL and pressing
  Enter is **not** confirmed the same way: driving this machine remotely, setting the `EDIT`
  control's text and delivering `WM_KEYDOWN`/`VK_RETURN` to it cross-process via `SendMessageW`
  reached `RailWindow.navigateFromAddressBar` but read back the *old* text — while a second,
  independent `GetWindowTextW` against the same `HWND` from outside the process confirmed the new
  text was there, moments before and after. Retried with a two-second delay (rules out a race) and
  with `SendMessageW(..., WM_GETTEXTLENGTH, ...)` in place of the `GetWindowTextLengthW` wrapper
  (rules out that function) — same stale read. Nothing in `AddressBar.swift` touches that text
  anywhere but `navigateFromAddressBar` and `syncAddressBarIfNeeded`, so the code has no path that
  would produce this. The remaining explanation is how this automation delivers synthetic input
  across process boundaries, not the shipped mechanism, which is the same "subclass the `EDIT`
  control's `WNDPROC`, catch `VK_RETURN`" shape MiniBrowserSwift already uses successfully. Worth
  confirming by hand.

One real bug surfaced and got fixed in the process: **holding `Alt` turns the other key into a
system key.** Windows sends `WM_SYSKEYDOWN`, not `WM_KEYDOWN`, for any key pressed while Alt is
held — and every binding this front answers is `⌥`-something. The first pass only handled
`WM_KEYDOWN`, so every Alt-chorded shortcut was silently swallowed by nothing (mouse and wheel
worked throughout, because those poll modifier state via `GetKeyState` rather than depending on
which message a keypress arrives as). `RailWindow.handle` now routes both through `handleKeyDown`,
which reports whether it recognised the key — `WM_SYSKEYDOWN` is swallowed only when a binding
matched, so `⌥F4`, `⌥Space` and plain `F10` still behave like system keys.

## Known issues

- **Keyboard focus needs asking for explicitly, and does not always win it.** SwiftPM links a plain
  executable as a console-subsystem app by default, so starting `six-windows.exe` also opens a
  console window — and Windows' foreground-lock rules can leave that console holding keyboard focus
  even after `RailWindow.show()` calls `SetForegroundWindow`/`SetFocus` on the rail explicitly. In
  practice this resolves itself once a person actually clicks into the rail window, so it has not
  blocked verifying anything, but it is not understood well enough to call fixed.
  `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` (dropping the console outright, the "correct"
  long-term fix) were tried and reverted: a live test showed the window then failing to appear at
  all, not even in Alt-Tab, for a reason not yet diagnosed. Reproduce that with `SIX_UI_DEBUG=1` set
  (which gates the `[six] window created, hwnd=…` trace) before trying the flags again.
- **GPU compositing is off**, deliberately, and with a way back. See "DPI and scale".

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  neither `RailModel` nor `RailKeyLookup` expose it. Whoever adds it next has
  `linux/Sources/SixUI/BrowserContent.swift` and the Mac's `NiriStripView` as the two existing
  readings of the same `NiriLayout` state.
- **A live-page budget.** Only the focused column ever gets a `WKView`; every other front's version
  of "more than one column can be live at once" is future work here too.
- **Persistence, history, bookmarks, profiles.** `RailModel` keeps one profile's strip in memory and
  loses it on exit. What has changed is that nothing is in the way any more: `SixBrowser` imports
  `SixCore`, so `AppDatabase`, `ProfileStore`, `SettingsStore`, `History` and `Bookmark` are all
  reachable, and a real SQLite round-trip has been run on this platform. It is work, not a blocker.

## Persistence: where to pick this up next

The question this section used to ask — *does the dependency graph a storage layer needs even
compile here?* — is answered, measured, and no longer the obstacle. `SixCore` builds, `SQLiteData`
builds, and a `@Table` type went through a migration, two inserts, a `.where {}.select()` and back
out of a real file on disk. `AppSupport.root` knows where six lives on Windows
(`%LOCALAPPDATA%\six`, spelled out rather than left to Foundation, which would have chosen the
roaming profile). What is left is the front's own work, and it is ordinary:

1. **A snapshot of the rail.** `SixCore` already carries `FileSnapshotStore` and `StatePersistence`
   — a versioned JSON file plus a debounced autosave — and they are generic over the snapshot type.
   The Mac's `AppStateSnapshot` is not in `SixCore`, so this front needs its own small `Codable`
   describing what `RailModel` holds: the workspaces, each column's tab id, URL and title, and which
   one had focus.
2. **The database under it.** `AppDatabase` is the system of record on every other front, and its
   migrations are plain `#sql` DDL that now compiles here. A profile row has to exist before
   anything keyed by profile can be written, which is what `ProfileStore` is for; `RailModel`'s
   `profileID` is a fresh `UUID()` per launch today and should become a real profile.
3. **A place to flush.** The Mac flushes on termination. Here that is `WM_CLOSE`/`WM_DESTROY` in
   `RailWindow`, before the message loop ends.

Nothing above needs a decision that has not already been made — it needs writing.
