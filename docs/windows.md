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
| built in | not yet proven anywhere; see "Unverified" below |

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

## Where things are

```
windows/Package.swift              a package of its own, the same reason linux/Package.swift is one:
                                    SwiftPM cannot leave a target out per platform, and `import WinSDK`
                                    only resolves where there is a Windows Swift toolchain to resolve
                                    it against.

windows/Sources/CRailInterop       <windowsx.h>'s mouse/wheel macros (GET_X_LPARAM and friends) and
                                    the WM_NCCREATE / GWLP_USERDATA dance a WNDPROC needs, both wrapped
                                    as inline C functions Swift can call — C macros are not callable
                                    from Swift, and pointer-sized-integer arithmetic done by hand on
                                    WPARAM/LPARAM is exactly the kind of thing that is easy to get
                                    subtly wrong. Let the C compiler check it instead.

windows/Sources/SixBrowser         RailModel: NiriLayout plus the tab metadata a placeholder column
                                    needs, no toolkit in it. `@testable import SixCore`, the same way
                                    linux/Sources/SixBrowser reaches NiriLayout's internal API.

windows/Sources/SixUI              RailWindow (the Win32 window, message dispatch), RailRendering
                                    (GDI painting), RailInput (mouse and wheel → RailModel).

windows/Sources/six-windows        main.swift: create the window, pump messages, done.
```

## What is built

- **The rail itself**: columns laid out left to right by `NiriLayout`, unchanged from every other
  front — the same gaps, the same column width as a fraction of the viewport, the same centring.
- **Open, close, focus, reorder**: a click opens a new column on empty background, focuses one under
  the pointer, and its "×" closes it — the three answers a click gives on every front, minus the page
  that would otherwise also receive it.
- **Workspaces**: `Alt` + the mouse wheel is this front's niri "Mod", the way `⌥` is
  `NiriScrollMonitor`'s on the Mac. Vertical steps a workspace, horizontal steps a column, and `Shift`
  turns either into "move the column, not just the focus" — the same split `KeyBindings` draws
  between `⌥↑/↓`/`⌥←/→` and their `⌥⇧` pairs.
- **Full width and centred focus** (niri's `toggleFullWidth`/`centerFocus`) are wired on `RailModel`
  and need no rendering work of their own: they only change the geometry `NiriLayout` reports, which
  the rail already redraws from on every paint.

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  `RailModel` does not expose it. Whoever adds it next has `linux/Sources/SixUI/BrowserContent.swift`
  and the Mac's `NiriStripView` as the two existing readings of the same `NiriLayout` state.
- **Real hotkeys.** Mouse and wheel are this commit; `KeyBindings`/`KeyContext` — the same
  platform-agnostic table the Mac and (eventually) every front read — is the next one, translating
  `WM_KEYDOWN` and `GetKeyState` into the table's `KeyCode`/`KeyModifiers` the way `KeyEvents.swift`
  does for `NSEvent`.
- **A real page.** A column is a title and a color, not a `WebView2` or anything else — see "Why
  Win32" above for the WinRT path this could grow into, and `../sixty/windows/WebKitAdapter` for the
  parallel WebKit-on-Windows experiment.
- **Persistence, history, bookmarks, profiles.** `RailModel` keeps one profile's strip in memory and
  loses it on exit. `SixCore` already has `AppDatabase`, `SettingsStore` and `StripState`'s Mac/Linux
  equivalents; wiring them in is future work, not a gap in what exists.
- **DPI scaling.** The rail's geometry is drawn in raw client pixels; a high-DPI monitor gets a rail
  sized for 96 DPI. `NiriLayout`'s own sizes are fractions of the viewport already — see CLAUDE.md's
  "Sizes are fractions of the viewport, not point constants" — so this is a matter of telling it the
  DPI-scaled viewport, not of changing how it lays out.

## Unverified

There is no Windows Swift toolchain on the machine this front was written on, so none of it has been
built. It was written against the shape SixCore, `linux/Package.swift` and the public `WinSDK`
surface are documented to have, not against a compiler's answer. The likeliest places for a first
build to fail, in the order worth checking:

1. **GDI object handles.** `RailRendering.swift` passes `HBRUSH`/`HPEN` where `SelectObject` and
   `DeleteObject` ask for `HGDIOBJ`, on the assumption that Windows headers define the GDI handle
   family (`HBRUSH`, `HPEN`, `HFONT`, …) as plain typedefs of `HGDIOBJ` rather than as `DECLARE_HANDLE`
   types with their own identity — true for GDI objects and false for stricter handles like `HWND`. If
   ClangImporter disagrees, every `SelectObject`/`DeleteObject` call in that file needs an explicit
   cast.
2. **SixCore on Windows at all.** Nothing in this front's own code stops `import SixCore` from also
   compiling `AppDatabase.swift`, and with it GRDB — Linux support for GRDB is established
   ([linux.md](linux.md)); Windows support is not something this session could confirm.
3. Everything downstream of a first `swift build --disable-automatic-resolution` in `windows/` — the
   usual first-pass Win32 interop mismatches (an `Int32` where a macro imported as a different width,
   a pointer where a distinct opaque handle type was expected) that only a compiler finds.

Building it — once there is a machine to build it on — is the same shape as Linux's:

```sh
swift build --disable-automatic-resolution --package-path windows
```
