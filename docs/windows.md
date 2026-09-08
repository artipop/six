# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting, no WebView yet. Where the
Mac reaches for the top bar and the assistant panel, this front for now draws the rail and nothing
past it — the tab rail and its mechanics are what this front's first commits are about, and
everything else (a real page, persistence, a menu) is deliberately later work.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting — no WinUI, no XAML |
| engine | none yet — a column is a placeholder card, not a `WebView` |
| language | Swift, the same source tree |
| storage | none yet — the rail does not survive a relaunch |
| built in | on the Windows dev machine directly — `scripts/six-windows.ps1` |
| verified | **yes** — built, run, and every rail mechanic below exercised by hand; see "Verified" |

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
future replacement for `SixUI`'s rendering once it needs a native look and a real `WebView2` host,
and nothing here forecloses it: `RailModel` (below) does not know GDI exists, the way `linux/`'s
`BrowserModel` does not know GTK exists.

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

windows/Sources/SixBrowser         RailModel: NiriLayout plus the tab metadata a placeholder column
                                    needs, no toolkit in it. RailKeyLookup: the same move for
                                    KeyBindings/KeyContext. Both `@testable import SixCoreShared`,
                                    the same seam linux/Sources/SixBrowser uses on SixCore.

windows/Sources/SixUI              RailWindow (the Win32 window, message dispatch), RailRendering
                                    (GDI painting, the placeholder colour palette), RailInput (mouse
                                    and wheel → RailModel), RailKeyInput (WM_KEYDOWN/WM_SYSKEYDOWN →
                                    RailKeyLookup → RailModel).

windows/Sources/six-windows        main.swift: create the window, pump messages, done.

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
3. **The runtime DLLs copied next to the built `.exe`.** Neither the Universal CRT API-set DLLs
   (`api-ms-win-crt-utility-l1-1-0.dll` and friends) nor the Swift runtime DLLs
   (`swiftCore.dll`, `swift_Concurrency.dll`, …) are guaranteed resolvable from a plain
   `CreateProcess` launch on every machine — a missing one surfaces as `STATUS_DLL_NOT_FOUND`
   (`0xC0000135`) with no further detail, whether or not the same DLL is technically present
   somewhere in `C:\Windows\System32\downlevel\` or the Windows SDK's own `Redist\ucrt\DLLs\x64\`.
   Copying both sets next to the `.exe` (which the script does after every build) is the reliable
   fix — cheaper than diagnosing why a system-wide install did not put them on the loader's path.
   (A `Microsoft Visual C++ Redistributable (x64)` install is still worth having regardless; it just
   is not sufficient on its own for this specific DLL.)

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
- **No DPI scaling.** The rail's geometry is drawn in raw client pixels; a high-DPI monitor gets a
  rail sized for 96 DPI. `NiriLayout`'s own sizes are fractions of the viewport already — see
  CLAUDE.md's "Sizes are fractions of the viewport, not point constants" — so this is a matter of
  telling it the DPI-scaled viewport, not of changing how it lays out.

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  neither `RailModel` nor `RailKeyLookup` expose it, and `⌥O` does nothing. Whoever adds it next has
  `linux/Sources/SixUI/BrowserContent.swift` and the Mac's `NiriStripView` as the two existing
  readings of the same `NiriLayout` state.
- **A real page.** A column is a title and a colour, not a `WebView2` or anything else — see "Why
  Win32" above for the WinRT path this could grow into, and `../sixty/windows/WebKitAdapter` for the
  parallel WebKit-on-Windows experiment.
- **Persistence, history, bookmarks, profiles.** `RailModel` keeps one profile's strip in memory and
  loses it on exit — and, per "Why `SixCoreShared`" above, cannot reach `AppDatabase`/`SettingsStore`
  without pulling in the dependency chain that crashes the compiler. Wiring real persistence back in
  is real future work, not a small follow-up: it needs either the upstream Swift bug fixed, the
  crash sites in `swift-structured-queries` patched properly (not just the two proven possible
  here), or a storage layer this front can use that does not route through that package at all.
