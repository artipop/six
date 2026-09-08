# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting. The engine is real
WebKit — the WebKit2 C API, the same family WebKitGTK's C API descends from — linked against the
actual Playwright-built `WebKit2.dll` that `../sixty`'s MiniBrowserSwift prototype already proved
out. A page loads, navigates, reports its title back, renders inside its own card, and answers a
click where the click looks like it landed. Where the Mac reaches for the top bar and the assistant
panel, this front draws the rail, an address bar and nothing past it.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting for the chrome — no WinUI, no XAML |
| engine | **real WebKit** (WebKit2 C API), software compositing — see "DPI and scale" |
| language | Swift, the same source tree |
| storage | none yet — the rail does not survive a relaunch |
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

## Why `SixCoreShared` and not `SixCore`

`windows/Package.swift` has **no package dependencies at all** — not on the root package, not on
`sqlite-data`, nothing. `SixCoreShared` takes `NiriLayout.swift`, `KeyBindings.swift` and
`KeyContext.swift` straight out of `six/` via three symlinks in `windows/Sources/SixCoreShared/`
(the same cross-target source-sharing move `swift-structured-queries` itself makes with its own
"Symbolic Links" folders — one file, one source of truth, still). This was not the first thing
tried, and the reason it won is worth keeping:

Depending on the root `SixCore` product the way `linux/Package.swift` does pulls in
`SQLiteData` → GRDB → `swift-structured-queries`, because `SixCore`'s `sources:` list compiles
`AppDatabase.swift` unconditionally regardless of whether a given front's own code ever touches it.
On **both** official Windows Swift toolchains this front was tried against — the `0.0.0+Asserts`
nightly and the `6.3.3-RELEASE` stable build — `swift-structured-queries`' keyPath
dynamic-member-lookup subscripts (`Type.self[keyPath: keyPath]`, the mechanism its whole "type-safe
query building" API is built on, used ~85 times across the package) crash `swift-frontend` with an
internal assertion:

```
Assertion failed: (path.size() == 1 && path[0].getKind() == ConstraintLocator::SubscriptMember) ||
  (path.size() == 2 && path[1].getKind() == ConstraintLocator::KeyPathDynamicMember),
  file …\swift\lib\Sema\CSSimplify.cpp, line 16426
```

This is a confirmed, **still open** upstream bug —
[swiftlang/swift#69386](https://github.com/swiftlang/swift/issues/69386), filed October 2023,
Windows-specific, no workaround documented. Two crash sites (`swift-structured-queries`'
`PrimaryKeyed.swift` and `Statements/Where.swift`) were patched locally via `swift package edit`
and confirmed to fix the crash *at that specific call site* — proving the diagnosis, not the fix:
the pattern recurs in dozens of the package's other files (`Select+DynamicMemberLookup.swift`
alone has it a dozen times, several inside `repeat each C`/variadic-generic functions), and patching
a popular third-party dependency's core mechanism call-by-call, in code whose *behaviour* (not just
whether it compiles) cannot be verified without a working SQLite round-trip, is not a small
undertaking. Routing around the dependency entirely was the smaller, safer move — and it costs
nothing this front needed anyway, since `RailModel` has no persistence yet regardless.

`combine-schedulers` needed a real, different fix on the way here (`swift package edit`, now folded
back since the dependency is gone — see git history if this resurfaces): every version of it lacks
Windows support outright, not as a version regression but as a gap that was never filled — its
non-Darwin lock implementation assumes `import Foundation` brings `pthread_mutex_t` along, true on
Linux (via Glibc) and false on Windows (swift-corelibs-foundation there wraps ucrt/WinSDK, no
pthreads anywhere). If a future front on this platform needs `swift-dependencies` or anything else
that pulls this package in, that fix is the one to redo: `os_unfair_lock_s`'s `#else` branch needs a
Windows case using `SRWLOCK`
(`InitializeSRWLock`/`AcquireSRWLockExclusive`/`ReleaseSRWLockExclusive`).

## DPI and scale

At this dev machine's 150% display scale, a live column used to draw its page 1.5x too large,
spilling past its own `HWND`, and clicks landed 1.5x away from whatever they appeared to hit — a
page that could sometimes be read and never used. That is fixed, by two calls that look wrong until
you know why they are there. **Both are load-bearing; do not "clean up" either without re-reading
this.**

**What WebKit's Windows port actually does.** It renders at `viewSize × deviceScaleFactor` and then
presents that surface into the window one backing pixel to one window pixel, with no downscale. The
device scale is the monitor's *effective* DPI, which follows the **process's** DPI awareness and
nothing finer. So under a per-monitor-aware process at 150%: view size 1390 physical pixels, device
scale 1.5, a 2085-pixel-wide surface blitted 1:1 into a 1390-pixel window. Measured directly — a
page that writes `innerWidth`/`devicePixelRatio` into its own title reported `iw=1390 dpr=1.5`
against a `WKView` `HWND` that `GetWindowRect` confirmed was exactly 1390 wide.

Hit-testing follows the same arithmetic, which is why the clicks were wrong and why this was not
cosmetic: the click at window pixel *x* is interpreted as CSS pixel *x*, but what is *drawn* at
window pixel *x* is CSS pixel *x/1.5*.

**What does not move it**, each measured rather than reasoned about:

| tried | result |
|---|---|
| `WKPageSetCustomBackingScaleFactor(page, 1.0)` | the page then reports `dpr=1`, rendering pixel-identical |
| `SetThreadDpiAwarenessContext(UNAWARE)` + `SetThreadDpiHostingBehavior(MIXED)` around `WKViewCreate` | backing scale still reads 1.5 — it is a process-level query |
| `DPI_AWARENESS_CONTEXT_SYSTEM_AWARE` for the process | system DPI *is* 144 on this machine; no change |
| creating the `WKView` with the rect divided by the scale, then resizing to full size | no difference — the bug is scale-invariant |
| `WKViewSetUsesOffscreenRendering(view, true)` | shrinks into a corner, rest blank |
| sizing the live view to the whole client area, as MiniBrowserSwift does | same overshoot; not about the card being small |

**The fix, first half — `main.swift` declares the process DPI-*unaware*.** Reporting 96 DPI is the
one lever that makes WebKit's own scale agree with the window it draws into: device scale 1.0,
surface size equal to view size, blit 1:1, correct. Windows then scales the whole window back up by
1.5 for the display. `DPI_AWARENESS_CONTEXT_UNAWARE_GDISCALED` rather than plain `..._UNAWARE`
because it makes Windows re-render GDI content at the real display scale instead of stretching the
bitmap, so the rail's own text stays crisp; the page is a bitmap upscale either way, and looks it.

**The fix, second half — `WebEngine` turns accelerated compositing off.** Unawareness alone fixed a
plain test page and left real ones (duckduckgo.com) drawing at two-thirds size anchored to the
bottom-left corner of their card. The accelerated path presents in real device pixels and ignores
the DPI virtualization the first half depends on; the software blit path honours it. So
`WKPreferencesSetAcceleratedCompositingEnabled(preferences, false)`, and every page takes the path
that works. The cost is GPU compositing — animations and video are the software path's problem now.

**What this leaves.** The page is rendered at 96 DPI and upscaled, so it is soft where a native
browser is sharp, and the rail lays out in logical rather than physical pixels. Both go away for
free the day WebKit's Windows port downscales its own surface by the device scale it rendered at, or
a newer Playwright WebKit build does (the one tested against is `webkit-2359`); at that point
`main.swift` goes back to `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` and the compositing
preference goes away. Neither is reachable from the public C API today.

Verified end to end, not by eye: a page laid out as a 4x3 grid of labelled cells, clicked at the
visual centre of one of them with a synthetic hardware-level click, reports back that cell and CSS
coordinates within a few pixels of its centre.

## Where things are

```
windows/Package.swift              No dependencies. SixCoreShared takes NiriLayout/KeyBindings/
                                    KeyContext straight out of six/ — see above for why not SixCore.

windows/Sources/SixCoreShared      Symlinks to the three real files in six/Niri and six/Input, not
                                    copies — git records them as real symlinks (mode 120000) even
                                    with `core.symlinks=false` locally, but a *checkout* on a machine
                                    with that setting and no Developer Mode still writes them out as
                                    plain text files containing the link target, which breaks the
                                    build. Recreate with `cmd /c mklink <link> <target>` if that
                                    happens — MSYS/git-bash's own `ln -s` silently makes a *copy*
                                    when it lacks the privilege, which is worse: the build still
                                    works and the file silently stops tracking the original.

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
                                    real engine DLL's own export table. Not the DLL itself, which is
                                    large and already lives wherever `playwright install webkit` put
                                    it — see "Building and running".

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
2. **The Swift toolchain's own `bin` directories on `PATH`.** Not automatic even once installed.
3. **The runtime DLLs copied next to the built `.exe`.** None of the Universal CRT API-set DLLs, the
   Swift runtime DLLs, or the WebKit2 engine and its `WebKitWebProcess`/`WebKitNetworkProcess`/
   `WebKitGPUProcess` helper `.exe`s are guaranteed resolvable from a plain `CreateProcess` launch —
   a missing CRT one surfaces as `STATUS_DLL_NOT_FOUND` (`0xC0000135`) with no further detail,
   whether or not the same DLL is technically present somewhere under `C:\Windows\System32\downlevel\`
   or the Windows SDK's own `Redist\ucrt\DLLs\x64\`. Copying all three sets is the reliable fix,
   cheaper than diagnosing why a system-wide install did not put them on the loader's path. (A
   `Microsoft Visual C++ Redistributable (x64)` install is still worth having; it is just not
   sufficient on its own.) The engine comes from `%LOCALAPPDATA%\ms-playwright\webkit-*`, which the
   script auto-discovers; pass `-PlaywrightWebKitDir` to point at a different build.

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
- **The page is upscaled, and GPU compositing is off** — both deliberate, both with a way out. See
  "DPI and scale".

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  neither `RailModel` nor `RailKeyLookup` expose it. Whoever adds it next has
  `linux/Sources/SixUI/BrowserContent.swift` and the Mac's `NiriStripView` as the two existing
  readings of the same `NiriLayout` state.
- **A live-page budget.** Only the focused column ever gets a `WKView`; every other front's version
  of "more than one column can be live at once" is future work here too.
- **Persistence, history, bookmarks, profiles.** `RailModel` keeps one profile's strip in memory and
  loses it on exit — and, per "Why `SixCoreShared`", cannot reach `AppDatabase`/`SettingsStore`
  without pulling in the dependency chain that crashes the compiler. See below for where to start.

## Persistence: where to pick this up next

Not started — `RailModel` has no database at all, in memory or otherwise. Before reaching for either
of the two hard options "Why `SixCoreShared`" names — get
[swiftlang/swift#69386](https://github.com/swiftlang/swift/issues/69386) fixed upstream, or patch
every one of `swift-structured-queries`' ~85 keyPath dynamic-member-lookup call sites and verify
each one's *behaviour* — there is a cheaper experiment nobody has run yet, worth trying first
precisely because it is cheap to rule out:

**Does plain GRDB, without `swift-structured-queries` in the graph at all, build on Windows?** The
crash is specifically in `swift-structured-queries`' `@dynamicMemberLookup` query-builder mechanism —
the `Type.self[keyPath: keyPath]` pattern `@Table`-generated `Draft` types and `Where`/`Select`
chaining both go through. `six/Data/AppDatabase.swift` itself is mostly plain `#sql("""...""")`
against GRDB directly; `@Table` is used in the four *record* files (`six/Data/SettingsStore.swift`,
`six/Browser/ProfileStore.swift`, `six/Browser/History.swift`, `six/Bookmarks/Bookmark.swift`), not
in the database layer's schema code. GRDB predates `swift-structured-queries` and does not use its
machinery for its own query interface, so there is a real chance it simply builds and runs here as
long as nothing pulls that package in behind it.

If that holds, a Windows storage layer becomes: depend on `GRDB` alone (not `SQLiteData`, so
`combine-schedulers` never enters the graph either — it only arrives through
`SQLiteData` → `Sharing` → `swift-dependencies`), and write plain `#sql` or GRDB's own
record/`FetchableRecord` APIs against `RailModel`'s existing shape — no `@Table`, no crash surface.
It would not share `AppDatabase`'s own schema code without either duplicating a Windows-safe subset
or reworking those four record files, which is a real design decision. But the first step — does
`swift build` on a throwaway package with a single `import GRDB` get past the frontend on Windows —
costs an afternoon, not a rewrite, and nobody has run it.
