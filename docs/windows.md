# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting. The engine is real
WebKit — the WebKit2 C API, the same family WebKitGTK's C API descends from — linked against the
actual Playwright-built `WebKit2.dll` that `../sixty`'s MiniBrowserSwift prototype already proved
out. A page loads, navigates, reports its title back, renders inside its own card at the display's
real resolution, and answers a click where the click looks like it landed. Above the rail is the
same band the Mac's `TopBar` occupies, and in the same place: the bar *is* the title bar, so which
profile you are in, the navigation buttons, the focused page's address and the window controls are
all on one line, the way they are on the Mac. Past that the Mac still has the assistant, the agent
panel and the overview, which this front does not draw.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting for the chrome — no WinUI, no XAML |
| engine | **real WebKit** (WebKit2 C API), software compositing — see "DPI and scale" |
| language | Swift, the same source tree — and now the same `SixCore`, not a subset of it |
| storage | the profiles are real rows in `six.sqlite`, each with its own WebKit data store, and the one on screen comes back after a relaunch; the rail itself does not persist yet |
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

## The top bar

The Mac's chrome is one 40-point band above the rail — profile, address, workspace stepper — and
this is that band in GDI. It replaced two stacked strips (a workspace caption over a bare `EDIT`),
for the reason the Mac collapsed the same thing into one bar: a browser has one row of chrome, and
the address belongs in it. `RailChrome.swift` is all of it.

Four things in it are worth knowing before changing any of them.

**Everything is measured in logical pixels and multiplied by `scale` at the point of use.** The
window is Per-Monitor-V2 aware, so an unscaled constant is *physical* pixels: at this machine's 150%
the bar came out two thirds of the height it should be, and every string in it two thirds the size.
`RailWindow.scale` is `GetDpiForWindow / 96`, refreshed on `WM_DPICHANGED` along with the fonts, and
`px(_:)` is the only way a number reaches GDI. The rail below is *not* converted: its columns are
fractions of the viewport, which scales itself.

**The fonts are Segoe UI, made once per DPI.** GDI's default object is `SYSTEM_FONT` — a Windows 3.1
bitmap face that neither scales nor antialiases — and that is what every string on this front used
to be drawn in, which is the whole of why it looked like a debug overlay. `refreshFonts` makes four
(`CLEARTYPE_QUALITY`, negative height so the size means character height) and deletes what it
replaces: an `HFONT` made inside `WM_PAINT` is an `HFONT` leaked at the repaint rate. The glyphs are
`Segoe MDL2 Assets`, the icon face every Windows 10 ships — as safe here as an SF Symbol on the Mac.

**One layout function serves painting and hit-testing.** `chromeLayout()` returns every rectangle
the bar owns; `drawTopBar` paints them and `chromeAction(x:y:)` reads the same values back, so a
button cannot be drawn anywhere but where it is clickable — the discipline `cardRect` already keeps
for the cards. An empty rectangle means "not this frame", which is how the address field disappears
on a workspace with no focused window, the way the Mac's does.

**The address field is a real `EDIT` sunk into a drawn pill.** The one thing a Win32 `EDIT` will not
let go of is its frame, so it is created without `WS_EX_CLIENTEDGE`, painted in the bar's own colours
through `WM_CTLCOLOREDIT`, and inset into a rounded rectangle drawn behind it — what shows around the
square control is the pill's edge. `Ctrl+L` selects what is in it, `Enter` navigates, `Esc` hands the
keyboard back to the rail.

The rest of the bar is the Mac's, item for item: the profile chip is `ProfileMenu.swift`'s dropdown
(a coloured dot with the profile's initial, its name, and a native popup menu — "a row of coloured
circles is fine for two profiles and unreadable for five"), the pips are `WorkspacePips`, and the
back/forward/reload buttons are drawn greyed rather than disabled, because a disabled control that
eats its click is worse than one that says no.

### The bar is the title bar

There is no switch for this on Windows. The caption is non-client area that the system owns, draws
and hit-tests, and the only way to put anything on that line is to tell the system the client area
covers it — and then answer for everything the caption used to do. `RailFrame.swift` is that answer,
and it is the shape every browser on this platform ends up with.

- **`WM_NCCALCSIZE` reclaims the top edge and nothing else.** `DefWindowProcW` runs first, because it
  is what knows how thick this monitor's frame is at this DPI; then `rgrc.0.top` is put back to the
  value that came in. The left, right and bottom borders stay the system's, so resizing there is
  still `DefWindowProcW`'s business and none of it had to be reimplemented.
- **A maximized window hangs off every edge of the monitor** by `SM_CYSIZEFRAME + SM_CXPADDEDBORDER`
  — 11 physical pixels here — and relies on the frame to swallow it. With no top frame left, that
  much has to be added back to `top` when maximized, or the first row of the bar is off the screen.
  Measured after the fix: window rect `-11,-11`, client rect starting at `0,0`.
- **`WM_NCHITTEST` is where the window becomes draggable again.** The top few pixels answer
  `HTTOP`/`HTTOPLEFT`/`HTTOPRIGHT` (a top edge that only resizes in the middle is a window whose
  corners have quietly stopped working); the three controls answer `HTMINBUTTON`/`HTMAXBUTTON`/
  `HTCLOSE`; a point on any control of ours answers `HTCLIENT`; everything else in the bar is
  `HTCAPTION`, which is what makes dragging and double-click-to-maximize work without another line
  of code. It asks `chromeAction(x:y:)` — the same function the click handler asks — so a control
  cannot be draggable and clickable at once.
- **The window controls are drawn here**, because they disappear with the caption: 46 logical pixels
  wide each (Windows' own width, and this is the one control on a window people aim at without
  looking), in the icon font's caption set, with Windows' hover colours — a light wash on the two on
  the left, and the red on close. `DefWindowProcW` does nothing useful with `HTMINBUTTON` on a
  window whose caption it no longer owns, so the press and the release are both handled here, and
  acting on the release means a mis-aimed click can still be taken back by sliding off.

What this is not is a *frameless* window: the three other borders, the shadow, snapping, Aero Snap
and the system menu all still work, because they were never taken away.

### The keys go through the queue, not through the window

`RailWindow.route` takes `WM_KEYDOWN`, `WM_SYSKEYDOWN` and `Alt`-held wheel messages out of
`GetMessageW`'s hand before they are dispatched, and this is not a refinement — it is the difference
between shortcuts that work and shortcuts that stop working the moment you click on a page. A
`WKView` is a child `HWND` that takes the keyboard focus, and a key sent to it never reaches this
window's procedure at all: every rail binding used to answer only while the chrome had focus. The
Mac has exactly this, for exactly this reason, and calls it `KeyRouter` (CLAUDE.md: "a local
`NSEvent` monitor is exactly what pulls events out of it"). Only what matched is swallowed, so
`⌥F4`, `⌥Space`, the page's own keys and everything typed into the address field stay somebody
else's.

### What the page says it is, on a timer

Three things the chrome draws belong to the page — the card's title, the address, and whether back
and forward can do anything — and WebKit announces none of them at a moment late enough to be true.
`didFinishNavigation` fires with the *previous* title still in place (a card labelled DuckDuckGo with
example.com in it, measured), and pushing onto the back-forward list is not announced at all. A
400 ms `WM_TIMER` asks (`RailLiveView.refreshLivePageState`) and repaints only on a change — the
"poll from Swift for anything that must wait" CLAUDE.md settles on for page state, and what the Mac
gets from `WebPage`'s observation for free.

## Profiles

A profile here is what it is everywhere else in six: a name, a colour, and its own cookies.

The rows come from **the same two tables the Mac reads** — `ProfileIdentity` and `ProfileStorage`,
through `SixCore`'s own `ProfileStore`, in `%LOCALAPPDATA%\six\six.sqlite`. An empty table is a new
browser and gets `Personal` and `Work`, the Mac's `Profile.defaults` in the Mac's palette. This is
the first thing on this platform to open `AppDatabase` in earnest.

**A database that will not open is fatal here, and that is deliberate.** It briefly was not: the
store was optional and a failed open left the profiles in memory for the run, on the reasoning that a
browser which will not start over a profiles table is worse than one that forgets. That reasoning was
wrong about what it was forgetting. A profile id is what every cookie jar, visit and bookmark is keyed
by, so a run with invented ids points WebKit at folders named after them and leaves the real site data
on disk under names nothing looks up again — every login gone, silently, and the next launch does it
again. `ProfileStore`'s own comment says the same thing about refusing to empty the table. Linux can
step over its database because all it loses is history; here the loss is silent and permanent, so this
front stops with the path in the message, the way `sixApp` does.

**Which profile was on screen is remembered**, in the settings table under `profile.selected` — a key
of its own rather than `profile.default`, which is a front *without* a profiles table inventing an id
to key its history by. An id that no longer names a row falls back to the first profile rather than to
nothing. The private profile is never written: it is in no table, and coming back into it after a
relaunch would be a private session that outlived the process it was private to.

The isolation is real, and it is `WebEngine`'s half: one `WKWebsiteDataStore` per profile, built from
a `WKWebsiteDataStoreConfiguration` whose nine directories and one cookie file all point under
`Profiles/<name>/WebKit`. That configuration has no "put it all under here" knob — each is named
separately, and one left unset lands in the port's default beside the executable, shared by every
profile, which is the opposite of the point. Sign in to something in one profile and the other has
never heard of it; the folders and `cookies.db` appear on disk the moment a profile first loads a
page.

Switching is `NiriLayout`'s doing and costs nothing: it already keeps a strip per profile, so
`activeProfileID = id` *is* the switch. The pages of the profile you left are hidden, not destroyed
(`RailLiveView` prunes against every profile's strip, not the one on screen), and a profile whose
rail is empty comes up empty — the Mac's rule, so that stepping away and back does not put a start
page where closing the last column had just taken it from.

**Private** is one more menu item: a profile written down nowhere, with the non-persistent data store
behind it, living until six quits. What it does not have is the Mac's editor — renaming, recolouring
and deleting are a text field and eight swatches, and this front has no control that can hold either;
a new profile names itself `Profile N` and takes the next colour in the palette.

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

**A DPI-unaware harness makes this front look broken when it is not, and the top bar has already
been reported as a scale bug on that evidence.** Windows answers a process that has not declared
awareness at 96 DPI for *every* query, diagnostics included, so a client rect, a cursor position or
a `ScreenToClient` result comes back divided by the display scale — while a `PrintWindow` capture
still hands over real pixels. Measuring the profile chip that way put it at client y 15..25 against
a picture that clearly drew it half again as tall, which reads exactly like "drawn at one size,
hit-tested at another". It was neither: 15..25 unaware is 22..37 physical, inside the chip's real
10..48 band, so the clicks landed and the numbers lied. The chrome draws and hit-tests through one
`chromeLayout()` and cannot disagree with itself, and `SIX_UI_DEBUG=1` prints the scale the window
actually has (`scale=1.5`). Call
`SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` first thing in anything
that measures this front, before it reads a rect or moves the cursor.

**Accelerated compositing is off** (`WKPreferencesSetAcceleratedCompositingEnabled(preferences,
false)`), and the reason has been measured rather than eyeballed. With the shim in place the
accelerated path is geometrically correct — it was the DPI-unaware approach it could not survive —
but it seams the page at **every tile boundary**, which is every 512 CSS pixels.

`WKPreferencesSetCompositingBordersVisible` settles what the line is: turned on, WebKit's own orange
tile border lands exactly on the seam that was first noticed running through duckduckgo's search
field. A probe page with a smooth `linear-gradient` in one half and a flat fill in the other, and a
1px marker at CSS x 512, then says what it costs: the marker, the tile border and a clear step in
the gradient all coincide, and the flat half shows nothing at all. So it is not a hairline and not
specific to one site — it is a visible discontinuity wherever a smooth gradient crosses a tile join,
which on a real page means headers, hero sections and soft shadows.

Note what this is **not**: the tile edge at CSS 512 is device pixel 768 at this display's 1.5, an
integer, so the fractional scale is not putting the join on a half-pixel. It reads as two tiles
rasterising the same gradient with independent rounding — a tiled-rasterisation defect in this
WebKit build, unrelated to the DPI work. Worth retrying against a non-Playwright build
([todo.md](todo.md)), since that is the other thing such a build would buy: GPU compositing, and with
it the animations and video that the software path now carries.

## Translation

A page in another language gets a globe in the top bar; pressing it translates the page in place,
pressing it again shows the original, and a third press puts the translation back. While a run is
going on the bar grows a second line saying how far it has got, and the rail below moves down by
exactly that much — `topChromeHeight` counts the banner, so the cards, the live view and the
hit-testing all follow from the one number they already followed.

**The engine is Bergamot** — Marian compiled to wasm, the same one Firefox translates with — and
almost none of it is in `windows/`. The page walk, the batching, the state machine, Show Original,
the model catalogue, the downloads and the engine driver are all `SixCore`, shared with the Linux
front and, above the seam, with the Mac. What this front provides is three things:

- **`RailScript`** — `WKPageCallAsyncJavaScript` wrapped so that the shared page walk can run its
  own JavaScript here. One argument goes in named `input`, carrying the arguments as JSON text; one
  string comes back. That is deliberate: the C API hands a result back as an object graph of
  `WKString`/`WKNumber`/`WKArray`/`WKDictionary`, and walking it into Swift values is a hundred
  lines that buy nothing when both sides can serialise a string. Everything else this front still
  owes — the readable-page extractor, highlights, `get_selection` — needs this same call.
- **`RailSandbox`** — a real `WKView` in a one-pixel `WS_POPUP` at −32000,−32000 that is never
  shown. WebKit's Windows port draws into an `HWND` and a view without one is not a view, so the
  window is not optional. Two preferences are set on it that no browsing page gets —
  `FileAccessFromFileURLs` and `UniversalAccessFromFileURLs` — because the page is a `file:`
  document that has to `fetch()` five megabytes of wasm and thirty of weights out of the folder it
  lives in. It browses in a non-persistent data store, so nothing it does can reach a profile.
- **`RailTranslation`** — which page, which languages, and when to offer.

**Where the weights come from.** Mozilla's Remote Settings, the same two collections Firefox reads
(`translations-wasm` and `translations-models`), served from `firefox-settings-attachments.cdn
.mozilla.net` without authentication. 106 directions, every one with English at one end, so Russian
to German is two models and one pivot inside the engine. Everything is verified against the SHA-256
in the record before it is moved into the cache at `%LOCALAPPDATA%\six\Translation\Bergamot`; a
model is roughly 35 MB and is fetched once. The Emscripten glue the wasm needs is the one piece that
cannot be downloaded — it is version-locked source that exists nowhere but the Firefox tree — so
`scripts/bergamot-payload.sh` vendors it into `six/Translation/Payload` as Swift, under the MPL,
and the Apple targets compile it away.

**The source language is guessed here rather than asked of the system.** There is no
`NLLanguageRecognizer` on Windows, so `LanguageGuess` in `SixCore` reads it out of the text —
script first, then the letters a script does not share, then the commonest words — and `<html lang>`
is checked against it rather than trusted. `LanguageGuessTests` pins thirty-one languages of one
ordinary sentence each. The target is the setting, or the language the interface is in; there is no
way to pick another one on this front yet, which is the main thing left undone.

### Two things this cost, both worth knowing

**Swift concurrency did not run on this front at all, and nothing said so.** On Windows the main
actor's executor is libdispatch's main queue, and a thread parked in `GetMessageW` never drains it:
a `Task { @MainActor in … }` was enqueued and then never executed. Measured with a standalone probe
before anything was built on it. `RailLoop` is the fix and it is eight lines of loop: libdispatch
exports `_dispatch_get_main_queue_handle_4CF` — a handle signalled when the main queue has work —
and `_dispatch_main_queue_callback_4CF`, which drains it on the calling thread, and
swift-corelibs-foundation's own `CFRunLoop` is built on the pair. So the loop waits on the message
queue *and* that handle with `MsgWaitForMultipleObjectsEx` and drains whichever woke it. Nothing
polls, and the window, its messages and the main actor stay on thread one.

Two blind alleys, so they are not walked again: `swift_task_enqueueMainExecutor_hook` is exported
and is never called on this toolchain, because the main actor's executor is implemented in Swift now
and enqueues onto the queue directly; and SE-0463's `ExecutorFactory`, which is the properly spelled
answer, does not exist in 6.3.3.

**`FileManager.replaceItemAt` is a `fatalError` on Windows, not a thrown error.** It is the obvious
call for "verified file, atomic swap" and it took the browser down the first time a model finished
downloading — `try?` in front of it catches nothing. Remove-if-present plus `moveItem` instead.
Anything else in six that reaches for it on this front will do the same thing.

**And `AppSupport.logs` had no Windows answer**: `.libraryDirectory` returns an empty array here, so
the first line six ever logged would have subscripted it. It is `%LOCALAPPDATA%\six\Logs\six.log`
now, and it is how a translation run is watched — `Log.info(.translation, …)` says what was offered,
what is being fetched and what was loaded.

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

windows/Sources/SixUI/Rail*        The window, the bar, the input, the live view — and, since
                                    translation, RailLoop (the message loop and the main-queue
                                    drain), RailScript (callAsyncJavaScript), RailSandbox (the
                                    off-screen page the wasm engine runs in), RailTranslation and
                                    RailTranslationChrome.

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

windows/Sources/SixBrowser         RailModel: NiriLayout plus the tab metadata every column needs,
                                    the URL a live one is at, and the profiles (read from and written
                                    to the same ProfileStore tables the Mac uses) — no toolkit and no
                                    WebKit2 in it. RailKeyLookup: the same move for
                                    KeyBindings/KeyContext. Both `@testable import SixCore`, the seam
                                    linux/Sources/SixBrowser already uses.

windows/Sources/SixUI              RailWindow (the Win32 window, message dispatch, and `route` —
                                    the key/scroll router in front of the whole queue),
                                    RailFrame (the title bar taken over: WM_NCCALCSIZE, the
                                    hit-testing that gives dragging and resizing back, and the three
                                    window controls),
                                    RailChrome (the top bar: metrics, fonts, palette, layout and
                                    painting), RailRendering (the cards, and the geometry everything
                                    else borrows back), RailInput (mouse and wheel), RailKeyInput
                                    (WM_KEYDOWN / WM_SYSKEYDOWN), ProfileChip (the profile dropdown),
                                    WebEngine + RailWebView (the WebKit2 wrapper, one website data
                                    store per profile), RailLiveView (positions the focused column's
                                    WKView over its card's body, and polls what the page says it is),
                                    AddressBar (a plain Win32 EDIT control, sunk into a drawn pill).

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
- The profile round-trip, both directions and each read out of `six.sqlite` rather than judged from
  the chip's repaint. Seeding `profile.selected` with Work brought six up in Work, with the menu's
  checkmark on Work; clicking Personal in that menu wrote Personal's id to the row, and the next
  launch came up in Personal. `profiles` and `profile_storage` hold the two rows with their data
  store ids, and `%LOCALAPPDATA%\six\Profiles` holds a folder per profile.

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
- **Typing an address and pressing Enter navigates** — the one thing the earlier pass could not
  confirm. Driving the `EDIT` cross-process with `SendMessageW` reached `navigateFromAddressBar` and
  read back the *old* text, repeatably, while the same `HWND` read from outside showed the new one.
  The shipped mechanism was never at fault, and the way to see that is to stop reaching across a
  process boundary: `Ctrl+L`, real `keybd_event` keystrokes, `Enter`, and the page loads.
  `[six] navigate: … typed=example.com url=https://example.com` in the `SIX_UI_DEBUG` trace, and
  Example Domain on screen with the card, the window title and the address field all agreeing.
- **The profile menu, end to end**: the chip opens the dropdown, `Work` switches to an empty rail
  (with the Mac's own "New window / click anywhere, or Ctrl+T" hint, and no address field, because
  there is no window to describe), a click opens a column there, `Profiles/Work/WebKit/cookies.db`
  appears on disk beside `Profiles/Personal`'s, and `Private` switches to the non-persistent one.
- `Ctrl+L`, `Ctrl+T`, `Ctrl+W`, `Ctrl+R`, `F5`, `Ctrl+[`, `Ctrl+]` — the keys that are menu items
  rather than table rows on the Mac — all answer, **including while the page holds the keyboard**,
  which is what `RailWindow.route` is for.
- **The frame, every part of it.** `WM_NCHITTEST` answers were read back out of the window with
  `SendMessageW` (a question, not a click — it steals no focus): `HTCAPTION` on the bar's empty
  stretches, `HTCLIENT` on the chip, the address and the buttons, `HTTOP`/`HTTOPLEFT`/`HTTOPRIGHT`
  along the top edge, `HTLEFT`/`HTBOTTOM`/`HTBOTTOMRIGHT` still on the system's own borders. Then by
  hand: a drag on an empty stretch moved the window by exactly the cursor delta (40,32), the close
  button closed it, minimize minimized it (`IsIconic` true), maximize and restore round-tripped, a
  double-click on the bar maximized it (`showCmd` 3), the maximized bar is not clipped, and hovering
  close paints it red.

Two traps for whoever drives this from a script next, since between them they cost an hour here:

- **`SendKeys` cannot test a shortcut.** It sends letters as `VK_PACKET` (vk=231, scan 0) — a
  Unicode character rather than a key — so nothing that matches on the key itself ever sees it. The
  `SIX_UI_DEBUG` key trace says so in as many words, which is what it is for. `keybd_event` with a
  virtual-key code is what a keyboard sends. Related, and now handled in `RailKeyInput.scanCode`:
  synthetic input often carries a zero scan code, and this front matches letters on the scan code
  (the physical key, the same on every layout — CLAUDE.md's Russian-layout lesson), so a key with
  none is asked of the layout instead.
- **A background process cannot raise a window**, so a synthetic click aimed "at the rail" can land
  on whatever is actually in front — here, another session's terminal. A harness should check
  `GetForegroundWindow` and refuse rather than click blind. `PrintWindow` with
  `PW_RENDERFULLCONTENT` needs none of that: it captures the rail *and* the WebKit child without
  touching focus, which is how every screenshot in this pass was taken — from a Per-Monitor-V2 aware
  process, or `GetWindowRect` answers in logical pixels and the capture comes out cropped rather
  than scaled.

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
- **The chrome's few strings are English only.** "New profile", "Private", "New window" and the
  placeholder card titles do not go through a string catalog, because this front has none —
  everything a person reads on the Mac and iOS goes through `Localizable.xcstrings`
  (docs/localization.md), and matching that here is its own piece of work.
- **No Snap Layouts flyout.** On Windows 11, hovering the maximize button of a window that answers
  `HTMAXBUTTON` gets the system's snap-layout menu for free — but only if the window also handles
  `WM_NCHITTEST` fast enough and the OS is 11. This dev machine is Windows 10 19045, where there is
  nothing to show, so nothing was built for it. If six ever runs on 11, that is the one thing a
  custom frame owes a user, and the hit-test already answers correctly.
- **The private profile is marked by its initial, not by a symbol.** The Mac puts eyeglasses in the
  dot; MDL2 has no obvious equivalent and a wrong guess draws a tofu box, so it says "P" on grey.

## What is not

- **The overview** (`⌥O`). `NiriLayout.isOverview` would flip happily, but this front does not draw
  the zoomed-out view yet, and a toggle nothing on screen answers to is worse than no toggle — so
  neither `RailModel` nor `RailKeyLookup` expose it. Whoever adds it next has
  `linux/Sources/SixUI/BrowserContent.swift` and the Mac's `NiriStripView` as the two existing
  readings of the same `NiriLayout` state.
- **A live-page budget.** Only the focused column ever gets a `WKView`; every other front's version
  of "more than one column can be live at once" is future work here too.
- **Persistence of the rail, history, bookmarks.** The rail itself still lives in memory and goes on exit —
  which columns were open, where they stood, what they were showing. Profiles are the exception and
  are done (above): rows in `six.sqlite`, folders on disk. Nothing is in the way of the rest either:
  `SixBrowser` imports `SixCore`, so `AppDatabase`, `SettingsStore`, `History` and `Bookmark` are all
  reachable, and the profiles are the proof that reading and writing them here works.
- **The bar's right-hand half.** The Mac's carries downloads, the extension actions, the bookmark
  star against the field, the agent panel and the overview; this one has the workspace stepper and
  the full-width toggle, because those two are the only ones whose subsystem exists on this front.

## Bookmarks, vectors and the embedder

sqlite-vec is in, and it goes in the opposite way round from the Mac. The SQLite this front links is the amalgamation
`scripts/six-windows.ps1` compiles, built *with* extension loading, so `sqlite-vec.c` compiles as a **loadable**
extension: every SQLite call inside it goes through the `sqlite3_api_routines` table it is handed at init, and
`sqlite3_vec_init(db, nil, nil)` — which is what `Database.loadSQLiteVecExtension()` does, and what works on Apple,
where loading is compiled out and those redefinitions vanish — hands it a null table. `Vectors.register()` calls
`sqlite3_auto_extension` instead, from the line above the first `AppDatabase.open()`, because an auto extension
reaches the connections opened after it and no others.

The embedder is the same model the Mac runs — `multilingual-e5-small` — reached through transformers.js in a second
`RailSandbox`, the off-screen page Bergamot already uses. `RailEmbedding` is the whole of the wiring on this side;
everything else is `SixCore`'s and shared with the GTK front. [bookmarks.md](bookmarks.md) has the model, the install
and the one line that had to be measured (ONNX Runtime dynamically imports its own glue, and a module import from a
`file:` document is refused however much file access the view has been given).

Measured here, Debug, int8, one wasm thread: 3.5 s to load the model, 0.32–0.36 s to embed a two-passage page, 1.0 s
for three pages. `SIX_VEC_SELFTEST=1` says whether the vector index exists at all; `SIX_EMBED_SELFTEST=1` saves three
pages — плов in Russian, pilaf in English, a page about reserved domain names — embeds them, asks five questions and
deletes what it wrote. Both write to the log rather than to stdout, because a `print` from a process whose stdout is a
file sits in a buffer until it exits.

**What is not here yet: a way to save a page by hand.** There is no star and no ⌃D — the bar's right-hand half is the
open item listed above, and the index is fed by the self-test alone. The Linux front has the star and uses the same
`BookmarkIndexer`, so this is a button rather than a feature.

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
2. **The database under it.** Done, for the one table everything else is keyed by: `RailModel`
   reads and writes real `ProfileStore` rows, so a profile id in a snapshot now names something that
   outlives the launch. `AppDatabase`'s other migrations are plain `#sql` DDL that compiles here, so
   history and bookmarks are the same shape of work.
3. **A place to flush.** The Mac flushes on termination. Here that is `WM_CLOSE`/`WM_DESTROY` in
   `RailWindow`, before the message loop ends.

Three things the profiles work settled that a snapshot has to account for, written down here because
they are easy to get wrong and cost nothing to know:

- **A strip per profile, not one strip.** `NiriLayout` keeps `strips[profileID]`, and this front now
  uses more than one of them. Anything that saves "the rail" saves every profile's, or switching
  profiles loses whichever one was not on screen. `RailModel.allTabIDs` is the existing walk over all
  of them — and it exists for the same distinction a snapshot needs: a column absent from the active
  strip has been closed, a column absent from `allTabIDs` no longer exists anywhere.
- **Which profile was on screen is already written down**, in `settings` under `profile.selected`, so
  a snapshot does not need a field for it — but it does need to agree with it. Two records of the
  same fact that can disagree is worse than one, so a snapshot should read that key rather than carry
  its own copy.
- **The private profile must not be in it.** It is written down nowhere by definition — no row, no
  folder, no place in a snapshot — which on the Mac is `AppStateSnapshot` filtering
  `profiles.filter { !$0.isPrivate }`.

Nothing above needs a decision that has not already been made — it needs writing.
