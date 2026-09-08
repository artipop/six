# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting. The engine is real
WebKit — the WebKit2 C API, the same family WebKitGTK's C API descends from — linked against the
actual Playwright-built `WebKit2.dll`, the same one `../sixty`'s MiniBrowserSwift prototype already
proved out. A page genuinely loads, navigates and reports its title back; what it draws does not
reliably stay
inside its own window at this dev machine's 150% display scale, a pre-existing WebKit2 Windows
compositing issue the unmodified reference prototype shares — see "Known issues". Where the Mac
reaches for the top bar and the assistant panel, this front for now draws the rail and nothing past
it — persistence and a menu are deliberately later work.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting for the chrome — no WinUI, no XAML |
| engine | **real WebKit** (WebKit2 C API) — loads and navigates; rendering has a known bug, see below |
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
forecloses it: `RailModel` (below) does not know GDI exists, the way `linux/`'s `BrowserModel` does
not know GTK exists.

## Why WebKit2 and not WebView2

The obvious pragmatic choice for a Windows engine is `WebView2` (Chromium/Edge) — Microsoft's own
embedding API, well documented, no exotic build needed. It was tried first, briefly: the SDK
downloads as a plain NuGet package and the headers extract cleanly. It was dropped without writing
any integration code, on a direct steer — six is a WebKit browser on every other front, and matching
engines matters more here than matching platform convention. `../sixty/windows/WebKitAdapter`
already had the harder problem (a real WebKit build that runs on Windows at all) solved, via the
Playwright-shipped WebKit binary; using it is the smaller task, and keeps six a WebKit browser
everywhere. See "Where things are" for what got copied from there and why.

## Why `SixCoreShared` and not `SixCore`

`windows/Package.swift` has **no package dependencies at all** — not on the root package, not on
`sqlite-data`, nothing. `SixCoreShared`, a target of its own, takes `NiriLayout.swift`,
`KeyBindings.swift` and `KeyContext.swift` straight out of `six/` via three symlinks in
`windows/Sources/SixCoreShared/` (the same cross-target source-sharing move
`swift-structured-queries` itself makes with its own "Symbolic Links" folders — one file, one source
of truth, still). This was not the first thing tried, and the reason it won is worth keeping:

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
undertaking. Routing around the dependency entirely was the smaller, safer move — and it happens to
cost nothing this front needed anyway, since `RailModel` has no persistence yet regardless (see
"What is not").

`combine-schedulers` needed a real, different fix on the way here and keeps it, patched the same way
(`swift package edit`, now folded back since the dependency is gone — see git history if this
resurfaces): every version of it lacks Windows support outright, not as a version regression but as
a gap that was never filled — its non-Darwin lock implementation assumes `import Foundation` brings
`pthread_mutex_t` along, true on Linux (via Glibc) and false on Windows (swift-corelibs-foundation
there wraps ucrt/WinSDK, no pthreads anywhere). If a future front on this platform needs
`swift-dependencies` or anything else that pulls this package in, that fix is the one to redo:
`os_unfair_lock_s`'s `#else` branch needs a Windows case using `SRWLOCK`
(`InitializeSRWLock`/`AcquireSRWLockExclusive`/`ReleaseSRWLockExclusive`), alongside the existing
Darwin (`os_unfair_lock`) and pthread branches.

## Persistence: where to pick this up next

Not started — `RailModel` has no database at all, in memory or otherwise (see "What is not"). Before
reaching for either of the two hard options "Why `SixCoreShared`" already names — get
[swiftlang/swift#69386](https://github.com/swiftlang/swift/issues/69386) fixed upstream, or patch
every one of `swift-structured-queries`' ~85 keyPath dynamic-member-lookup call sites and verify each
one's *behaviour*, not just that it compiles — there is a cheaper experiment nobody has run yet, worth
trying first precisely because it is cheap to rule out:

**Does plain GRDB, without `swift-structured-queries` in the graph at all, build on Windows?** The
crash write-up in [UPSTREAM.md](../UPSTREAM.md) (section 3) is specifically in
`swift-structured-queries`' `@dynamicMemberLookup` query-builder mechanism — the
`Type.self[keyPath: keyPath]` pattern `@Table`-generated `Draft` types and `Where`/`Select` statement
chaining both go through. `six/Data/AppDatabase.swift` itself is mostly plain `#sql("""...""")`
macro calls against GRDB directly, for schema and migrations — `@Table` (and the crash-prone
query-builder syntax it enables) is used elsewhere, in the four *record* files
(`six/Data/SettingsStore.swift`, `six/Browser/ProfileStore.swift`, `six/Browser/History.swift`,
`six/Bookmarks/Bookmark.swift`), not in the database layer's own schema code. GRDB is the older,
mature, portable SQLite wrapper `SQLiteData` sits on top of — it predates and does not use
`swift-structured-queries`' dynamicMemberLookup machinery for its own query interface, so there is a
real chance it simply builds and runs on Windows *without ever hitting the bug in #69386 at all*, as
long as nothing pulls `swift-structured-queries` in behind it.

If that holds, a Windows-specific storage layer becomes: depend on `GRDB` alone (not `SQLiteData`,
not `swift-structured-queries`, so `combine-schedulers` never enters the graph either — see
[UPSTREAM.md](../UPSTREAM.md) (section 4), the other blocker "Why `SixCoreShared`" names, which only
arrives *through* `SQLiteData` → `Sharing` → `swift-dependencies`), and write plain `#sql` macro calls
or GRDB's own record/`FetchableRecord` APIs against `RailModel`'s existing shape — no `@Table`, no
dynamicMemberLookup query-builder syntax, no crash surface. It would not share `AppDatabase`'s own
schema code (still gated behind `@Table` on the record side) without either duplicating a
Windows-safe subset of it or reworking those four record files to stop generating dynamicMemberLookup
machinery everywhere — a real design decision, not a one-line fix — but it is a substantially smaller
undertaking than either option "Why `SixCoreShared`" names, and the first step (does `swift build` on
a throwaway package with a single `import GRDB` even get past the frontend on Windows) costs an
afternoon, not a rewrite. Nobody has run that first step yet; it is the natural place for a future
session to start.

## Where things are

```
windows/Package.swift              No dependencies. SixCoreShared takes NiriLayout/KeyBindings/
                                    KeyContext straight out of six/ — see above for why not SixCore.

windows/Sources/SixCoreShared      Symlinks to the three real files in six/Niri and six/Input, not
                                    copies — git records them as real symlinks (mode 120000) even
                                    with `core.symlinks=false` locally, but a *checkout* on a machine
                                    with that setting and no Developer Mode still writes them out as
                                    plain text files containing the link target, which breaks the
                                    build. Recreate with `cmd /c mklink <link> <target>` (respects
                                    Developer Mode's unprivileged symlink creation) if that happens —
                                    MSYS/git-bash's own `ln -s` silently makes a *copy* instead of a
                                    symlink when it lacks the privilege, which is worse: the build
                                    still works, but the file silently stops tracking edits to the
                                    original.

windows/Sources/CRailInterop       <windowsx.h>'s mouse/wheel macros (GET_X_LPARAM and friends), the
                                    WM_NCCREATE / GWLP_USERDATA dance a WNDPROC needs, and the cursor-
                                    loading / key-state helpers that dodge two more ClangImporter
                                    rough edges (below) — all wrapped as inline C functions Swift can
                                    call. Let the C compiler check the types instead of hand-translating
                                    macros and WPARAM/LPARAM arithmetic into Swift.

windows/Sources/CWebKit2           The WebKit2 C API headers, copied unmodified from
                                    ../sixty/windows/WebKitAdapter/Sources/CWebKit2 — whoever built
                                    the matching WebKit2.dll adapted them to avoid <windows.h> types
                                    at the C boundary (a Clang-modules submodule-visibility issue
                                    under Swift's ClangImporter), using layout-compatible plain
                                    structs and `void *` instead, cast back to HWND at the Swift call
                                    site (see WebEngine.swift). Header-only; shim.c exists only
                                    because SwiftPM wants a translation unit for the target.

windows/vendor/WebKit2             WebKit2.lib/.def/.exp — the import library generated from the
                                    real engine DLL's own export table, copied from the same place.
                                    Not the DLL itself, which is large and already lives wherever
                                    `playwright install webkit` put it — see "Building and running".

windows/Sources/SixBrowser         RailModel: NiriLayout plus the tab metadata every column needs,
                                    live or not, and (once a column is live) the URL it is at — no
                                    toolkit and no WebKit2 in it. RailKeyLookup: the same move for
                                    KeyBindings/KeyContext. Both `@testable import SixCoreShared`,
                                    the same seam linux/Sources/SixBrowser uses on SixCore.

windows/Sources/SixUI              RailWindow (the Win32 window, message dispatch), RailRendering
                                    (GDI painting, the placeholder colour palette, the top chrome's
                                    own strip heights), RailInput (mouse and wheel → RailModel),
                                    RailKeyInput (WM_KEYDOWN/WM_SYSKEYDOWN → RailKeyLookup →
                                    RailModel), WebEngine + RailWebView (the WebKit2 wrapper: one
                                    WKContext, one WKView per column that has ever been focused),
                                    RailLiveView (positions/shows/hides the focused column's WKView
                                    over its card's body, below the header GDI still draws the title
                                    and "×" in), AddressBar (a plain Win32 EDIT control, one for the
                                    window, showing and editing the focused column's URL — see
                                    "Verified" for what navigating through it actually does).

windows/Sources/six-windows        main.swift: declare DPI awareness, create the window, pump
                                    messages, done.

scripts/six-windows.ps1            Build (and optionally run) it. See "Building and running".
```

## Building and running

```powershell
./scripts/six-windows.ps1 build   # compile, copy the runtime DLLs next to the .exe
./scripts/six-windows.ps1 run     # build, then launch it
```

The script exists because a plain `swift build` in `windows/` needs three things arranged around it
that cost real time to work out, and are worth never re-deriving:

1. **The MSVC linker on `PATH`.** `vcvars64.bat`'s environment has to be imported into the current
   process; the script does this itself rather than requiring a "Developer PowerShell" session.
2. **The Swift toolchain's own `bin` directories on `PATH`.** Not automatic even once installed —
   `%LOCALAPPDATA%\Programs\Swift\Toolchains\<version>+Asserts\usr\bin` and
   `…\Runtimes\<version>\usr\bin`.
3. **The runtime DLLs copied next to the built `.exe`.** None of the Universal CRT API-set DLLs
   (`api-ms-win-crt-utility-l1-1-0.dll` and friends), the Swift runtime DLLs (`swiftCore.dll`,
   `swift_Concurrency.dll`, …), or now the WebKit2 engine itself (`WebKit2.dll`, `WebCore.dll`,
   `JavaScriptCore.dll`, and the `WebKitWebProcess`/`WebKitNetworkProcess`/`WebKitGPUProcess` helper
   `.exe`s it spawns) are guaranteed resolvable from a plain `CreateProcess` launch on every machine
   — a missing CRT one surfaces as `STATUS_DLL_NOT_FOUND` (`0xC0000135`) with no further detail,
   whether or not the same DLL is technically present somewhere in `C:\Windows\System32\downlevel\`
   or the Windows SDK's own `Redist\ucrt\DLLs\x64\`. Copying all three sets next to the `.exe` (which
   the script does after every build) is the reliable fix — cheaper than diagnosing why a
   system-wide install did not put them on the loader's path. (A
   `Microsoft Visual C++ Redistributable (x64)` install is still worth having regardless; it just is
   not sufficient on its own for the CRT API-set DLL.) The WebKit2 engine itself comes from wherever
   `playwright install webkit` (or `npx playwright install webkit`, run once with Node available) put
   it — `%LOCALAPPDATA%\ms-playwright\webkit-*` — which the script auto-discovers; pass
   `-PlaywrightWebKitDir` to point at a different build.

Two Win32 environment quirks worth knowing if this script or its approach is ever revisited:

- **Symlink creation needs Developer Mode**, a one-time Windows setting
  (`Settings → Privacy & security → For developers`), or every `git clone`/`swift package edit` of a
  dependency that itself uses symlinks (GRDB, `swift-issue-reporting`, `swift-structured-queries`
  all do, back when this front still depended on them) fails outright with a permission error.
- **`SW_SHOWDEFAULT` silently does not show the window** when the process was started with
  redirected stdout/stderr (as any script capturing build output for logging will do) — it defers to
  the launching process's own `STARTUPINFO.wShowWindow`, which such a launch often leaves unset.
  `RailWindow.show()` uses `SW_SHOWNORMAL` instead, which shows the window unconditionally; the
  script itself launches the built `.exe` with `UseShellExecute = $true` for the same reason.

## Verified

Built and run for real on the Windows dev machine (not just compiled — every mechanic below was
exercised by hand and confirmed working):

- Open a column by clicking empty background; focus one by clicking it; close one by clicking its
  "×".
- Placeholder columns are each a distinct, stable colour (picked from the tab's own id, so a column
  keeps its colour when the rail reorders it) — without this, every unfocused card was the same grey
  rectangle and there was no way to tell two open tabs apart short of clicking each one.
- `Alt` + mouse wheel steps a workspace (vertical) or a column (horizontal); `Shift` turns either
  into the "move it, don't just focus it" variant.
- `⌥←/→` (focus a column), `⌥⇧←/→` (reorder it), `⌥⇧↑/↓` (move it to the workspace above/below,
  confirmed by watching the workspace label change) all answer through the real `KeyBindings` table.
- The focused column's `WKView` genuinely loads its start page, navigates when the address changes,
  and reports its title back through `WKPageNavigationClientV3`'s `didFinishNavigation` into
  `RailModel.setTitle` — confirmed by watching a card's placeholder title ("New Tab 1") get replaced
  by the real page's title once it loads. What is *not* verified working is the rendering staying
  inside its own bounds — see "Known issues".
- The address bar itself (`AddressBar.swift`) shows the focused column's URL and repositions on
  resize, confirmed by screenshot. Typing a URL and pressing Enter, end to end, is **not** confirmed
  the same way the mechanics above are: this dev machine is driven remotely, and the one automated
  test tried — setting the `EDIT` control's text and delivering `WM_KEYDOWN`/`VK_RETURN` to it
  cross-process via `SendMessageW` — reached `RailWindow.navigateFromAddressBar` (the debug trace
  fired, `SixRailGetUserData` resolved the same `RailWindow` instance) but read back the *old* text,
  not the text a second, independent `GetWindowTextW` call against the identical `HWND` confirmed was
  actually there, moments before and after, from outside the process. Retried with a two-second
  delay between setting the text and sending Enter (rules out a race) and with the read routed
  through `SendMessageW(..., WM_GETTEXTLENGTH, ...)` directly instead of the `GetWindowTextLengthW`
  wrapper (rules out that specific function) — same stale read both times. Nothing in
  `AddressBar.swift` reads or writes that text anywhere but `navigateFromAddressBar` and
  `syncAddressBarIfNeeded` (confirmed via a trace that the latter fires exactly once, on the first
  paint, and never again while there is only one column), so the code has no path that would produce
  this on its own. The remaining explanation is something about how this remote automation delivers
  synthetic input across process boundaries here — the same environment that also cannot `taskkill`
  its own child processes after a while ("Access is denied", see the zombie-PID workaround in
  `scripts/six-windows.ps1`'s revision history) — not a defect in the shipped mechanism, which is the
  same "subclass the `EDIT` control's `WNDPROC`, catch `VK_RETURN`" shape `../sixty`'s own
  MiniBrowserSwift address bar already uses successfully. Whoever is at the real keyboard should
  confirm this by hand before relying on it.

One real bug surfaced and got fixed in the process, worth knowing about for any future Win32 work on
this front: **holding `Alt` turns the *other* key into a system key.** Windows sends
`WM_SYSKEYDOWN`, not `WM_KEYDOWN`, for any key pressed while Alt is held — and every binding in
`KeyBindings` that this front answers is `⌥`-something. The first pass only handled `WM_KEYDOWN`, so
every Alt-chorded shortcut was silently swallowed by nothing (mouse and wheel worked throughout,
because those poll modifier state directly via `GetKeyState` rather than depending on which message
a keypress arrives as). `RailWindow.handle` now handles both messages through the same
`handleKeyDown`, which reports back whether it actually recognised the key — `WM_SYSKEYDOWN` is only
swallowed (returns `0`) when a binding matched; anything else falls through to `DefWindowProcW`, so
`⌥F4`, `⌥Space` and plain `F10` still behave like system keys instead of being silently eaten too.

## Known issues

- **Keyboard focus needs asking for explicitly, and does not always win it.** SwiftPM links a plain
  executable as a console-subsystem app by default, so starting `six-windows.exe` also opens a
  console window — and Windows' foreground-lock rules can leave that console holding keyboard focus
  even after `RailWindow.show()` calls `SetForegroundWindow`/`SetFocus` on the rail explicitly. In
  practice this has resolved itself by the time a person actually clicks into the rail window (which
  legitimately grants it focus), so it has not blocked verifying any mechanic above, but it is not
  understood well enough to call fixed. `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` linker flags
  (dropping the console outright, the "correct" long-term fix) were tried and reverted: a live test
  showed the window then failing to appear at all — not even in Alt-Tab — for a reason not yet
  diagnosed. Whoever revisits this should reproduce that failure with `SIX_UI_DEBUG=1` set (gates
  the `[six] window created, hwnd=…` trace in `RailWindow.create`) before trying the flags again.
- **A live column's rendered content does not reliably stay inside its own window, at this dev
  machine's 150% display scale.** This is the main open problem, and it is a pre-existing WebKit2
  Windows compositing bug, not something specific to this front's code — the chain of evidence:
  - `RailLiveView.setFrame` positions the `WKView`'s `HWND` correctly: confirmed with a
    `SIX_UI_DEBUG=1` trace comparing the intended rect against `GetWindowRect` (converted to the
    parent's client coordinates), which matched exactly. What draws inside that correctly-positioned
    `HWND` does not respect its bounds regardless.
  - Seven different fixes were tried and did not resolve it: `WKViewSetUsesOffscreenRendering(view,
    true)` (reproduced, exactly, the "shrinks into a corner, rest blank" failure MiniBrowserSwift's
    own source comment already documents rejecting for the logically adjacent reason — dividing the
    rect by backing scale); `WKViewWindowAncestryDidChange` after `WKViewSetIsInWindow` (kept, since
    it is a reasonable call regardless, but made no measurable difference alone);
    `DPI_AWARENESS_CONTEXT_SYSTEM_AWARE` in place of `..._PER_MONITOR_AWARE_V2` for the whole process
    (no difference); moving live-view creation/positioning out of `WM_PAINT`'s
    `BeginPaint`/`EndPaint` bracket, on the theory that resizing a hardware-composited child window
    mid-paint could confuse the compositor (no difference); `WKPageSetCustomBackingScaleFactor(page,
    1.0)` right after creation (confirmed reaching WebKit — `WKPageGetBackingScaleFactor` reads back
    `1.0` afterward instead of the auto-detected `1.5` — but the rendered overflow was
    pixel-for-pixel identical); creating the `WKView` with its rect divided by the display's scale
    and then immediately resizing it to the real, full-size rect via `setFrame` (mirroring what a
    resize message right after creation would do — also no difference); and scoping
    `SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_SYSTEM_AWARE)` around the `WKViewCreate` call
    specifically, rather than the whole process (`WKPageGetBackingScaleFactor` still read back the
    same `1.5` regardless, so whatever queries the monitor's scale does not consult the creating
    thread's DPI awareness context at all). See `WebEngine.makeView`'s own doc comment for exactly
    where each of the last three lived in the code.
  - Sizing the live view to the *entire* window's client area — matching MiniBrowserSwift's own
    layout exactly, not a rail card's smaller sub-rect — still showed the bug. So this is not
    specific to confining a `WKView` to something smaller than the window either.
  - Rebuilding and running `../sixty/windows/WebKitAdapter`'s MiniBrowserSwift itself, unmodified,
    fresh, today: **the identical symptom.** MiniBrowserSwift's own source comment already documents
    a related, accepted-not-fixed case of this same class of bug ("YouTube's content column landing
    past the right edge on some pages... wins by default until there's a real fix for the narrower
    issue") — this front's smaller, more constrained card rect just makes the same underlying
    compositing bug far more visible than MiniBrowserSwift's nearly-full-window layout does.
  - The last three fixes above were verified with a sharper method than eyeballing a live window:
    launch built with `SIX_UI_DEBUG=1`, read the `WKView`'s own `GetWindowRect` from outside the
    process, screenshot a padded region around it from a DPI-*aware* capture process (a DPI-unaware
    one — plain PowerShell, unless it first calls `SetProcessDpiAwarenessContext` itself — reads back
    a virtualized 96 DPI regardless of the real display, which silently invalidates both the rect and
    the screenshot together, not just one of them; a real, physically-correct screenshot needs both
    sides DPI-aware, or neither), and draw a rectangle on the exact real bounds before comparing
    against the page's own content — so "does the content cross this line" is a pixel fact, not an
    impression. Every one of the three still showed content crossing it, in the same direction (past
    the right and bottom edges) and by roughly the same fraction (~1.5×, matching this display's own
    scale) every time.

  Nothing here points at a fix available from the embedding side — Swift, `WKView`'s own C API, or
  this front's window handling. The consistent ~1.5× overshoot, unmoved by every knob this API
  exposes for it (the page-level scale property, the creating thread's DPI awareness, the process's
  own DPI awareness mode, the units of the rect handed to `WKViewCreate` itself), points at WebKit's
  Windows port querying the monitor's scale a second time from somewhere none of these reach — most
  likely a direct system DPI call inside the view's own internal layout code, applied on top of a
  rect this front already gave it in real device pixels. A real fix most likely needs either a newer
  Playwright WebKit build (`playwright install webkit` pulls whatever is current; the one this was
  tested against is `webkit-2359`) or a patch to WebKit's own Windows-port compositing code — both
  outside what a consumer of the public C API can reach from here.

  **The practical consequence: clicks land on the wrong thing.** Mouse input to the `WKView`'s child
  `HWND` arrives in that `HWND`'s own real, correctly-sized coordinate space (confirmed above, and
  Windows delivers `WM_LBUTTONDOWN`/`WM_MOUSEMOVE` in physical client pixels regardless of what the
  compositor is showing) — but what a person actually *sees* at any given point on screen is content
  from a differently-scaled, differently-positioned layout, per the overshoot above. So a click aimed
  at, say, a page's own search box by eye lands at that same screen position translated into the
  `HWND`'s coordinate space, which is not where the search box's *real* hit-test rectangle is inside
  WebKit's own oversized layout — confirmed by hand: clicking into a page's own input field routinely
  focuses something else on the page, or nothing at all, at this dev machine's 150% scale. This is not
  a separate bug from the rendering overshoot above — same root cause, same fix (or lack of one) — but
  worth stating on its own because it is the difference between "the page looks wrong" and "the page
  cannot actually be used": text can often still be read past the visual cropping, but a form, a link,
  or anything else that needs a precise click is not reliably reachable at all right now.
- **DPI scaling of the rail's own chrome is, incidentally, fine.** `main.swift` declares
  `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` (originally to chase the bug above), which means
  `WM_SIZE` now reports genuine physical pixels rather than a DPI-virtualized value — and since
  `NiriLayout`'s own sizes are already fractions of the viewport (CLAUDE.md's "Sizes are fractions of
  the viewport, not point constants"), the GDI-drawn cards, gaps and text scale correctly with the
  real screen without this front doing anything further about it.

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  neither `RailModel` nor `RailKeyLookup` expose it, and `⌥O` does nothing. Whoever adds it next has
  `linux/Sources/SixUI/BrowserContent.swift` and the Mac's `NiriStripView` as the two existing
  readings of the same `NiriLayout` state.
- **A real, *usably rendered* page.** The engine is real WebKit and a live column genuinely loads
  and navigates — see "Verified" — but the "Known issues" rendering bug means what is on screen is
  not yet something to actually browse with, even now that `AddressBar.swift` gives a column
  somewhere to navigate *to* — see "Verified" for the one part of that path (Enter actually firing a
  navigation) this session could not confirm by hand. A live-page budget (only the focused column
  gets a `WKView`; every other front's own version of "more than one column can be live at once" is
  future work here too) is also not built.
- **Persistence, history, bookmarks, profiles.** `RailModel` keeps one profile's strip in memory and
  loses it on exit — and, per "Why `SixCoreShared`" above, cannot reach `AppDatabase`/`SettingsStore`
  without pulling in the dependency chain that crashes the compiler. Wiring real persistence back in
  is real future work, not a small follow-up — see "Persistence: where to pick this up next" above
  for the cheap experiment nobody has run yet and the two harder options behind it.
