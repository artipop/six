# Windows — Win32

six on Windows is a fourth front over the same `NiriLayout`, built with nothing but the Windows
Swift toolchain's own `WinSDK` module: plain Win32 windows, GDI painting. The engine is real
WebKit — the WebKit2 C API, the same family WebKitGTK's C API descends from — linked against the
actual Playwright-built `WebKit2.dll` that `../sixty`'s MiniBrowserSwift prototype already proved
out. A page loads, navigates, reports its title back, renders inside its own card at the display's
real resolution, and answers a click where the click looks like it landed. Above the rail is the
same band the Mac's `TopBar` occupies, and in the same place: the bar *is* the title bar, so which
profile you are in, the navigation buttons, the focused page's address and the window controls are
all on one line, the way they are on the Mac. Since the parity pass it also has what the Linux front
had and this one did not — history, the rail across a relaunch, the overview, a live-page budget
with pictures of the pages it gives back, and site permissions. Past that the Mac still has the
assistant and the agent panel.

| | |
|---|---|
| toolkit | **Win32** (`WinSDK`), GDI painting for the chrome — no WinUI, no XAML |
| engine | **real WebKit** (WebKit2 C API), software compositing — see "DPI and scale" |
| language | Swift, the same source tree — and now the same `SixCore`, not a subset of it |
| storage | the profiles are real rows in `six.sqlite`, each with its own WebKit data store; the one on screen and every profile's rail come back after a relaunch, and history is the Mac's `visits` table |
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

A page in another language gets the Mac's 文A translate mark in the top bar; pressing it translates the page in place,
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
  lines that buy nothing when both sides can serialise a string. The readable-page extractor
  behind bookmarks runs through it already; highlights and `get_selection` will need the same call.
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
                                    a path dependency takes its identity from the directory, so
                                    the name is pinned here rather than left to whatever the
                                    checkout is called), on sqlite-data, and on
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
                                    RailTranslationChrome — and, since the parity pass,
                                    RailThumbnails (pictures of pages), RailOverview,
                                    RailPermissionBar, RailListPanel (the History and Site
                                    Permissions windows) and RailPanels (the "⋯" menu).

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
                                    store per profile), RailLiveView (positions every live column's
                                    WKView over its card's body, keeps them within the budget, and
                                    polls what the pages say they are),
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
- **WebMCP** ([webmcp.md](webmcp.md)): `SIX_WEBMCP_SELFTEST=<file URL of Tests/WebMCP/webmcp.html>`
  drives a page's `registerTool` through the polyfill and back — registration, a call, a timeout
  whose `AbortSignal` reaches the tool, unregistering by `abort()`, and a navigation in the middle of
  a call — and prints 15 checks and `PASS` to the log. Measured on 2026-09-13 in a throwaway
  `LOCALAPPDATA`. It settled two facts on the way: a `file:` page is a secure context in this WebKit,
  and `WKPageCallAsyncJavaScript` runs in the page's world, which is where the polyfill lives. The
  address bar counts the page's tools in a badge (`RailWebMCP`), with no list behind it yet.
  `SIX_WEBMCP=1` switches WebMCP on without the self-test; so does the Mac's setting, since the
  settings table is shared.
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

- **The overview's hands.** Dragging a window to another row and renaming a workspace are the Mac's;
  this overview looks and goes, it does not rearrange.
- **The bar's right-hand half.** The Mac's carries downloads, the extension actions, the agent panel
  and the overview; this one has the bookmark button, the translate button, the workspace stepper,
  the full-width toggle and "⋯", because those are the ones whose subsystem exists on this front.
- **A camera or a microphone for a page.** The engine's gap, not six's — see "Site permissions".

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

**The bookmark button** sits against the right end of the address field, where the Mac's does and for the reason
`ContentView.BookmarkButton` gives: it comes and goes with the field, because a bookmark button on an empty workspace
is a control about nothing. `⌃D` is the same action, in the `handleChromeKey` table beside ⌃L/⌃T/⌃W/⌃R, since ⌘D is a menu
item on the Mac rather than a row in `KeyBindings`. Filled and in the profile's colour when the page is saved, hollow
when it is not, dim and unclickable when there is nothing to save — a private profile, or a column with no address
yet; `chromeAction` returns `nil` in that case so the hand cursor does not promise a click that would be a no-op.

It is a book's ribbon, the Mac's `bookmark`/`bookmark.fill`, and it is **drawn** rather than taken from the icon
font — as is the translate button's 文A tile. Every Segoe MDL2 codepoint from E700 to E8FF and F000 to F0FF was
rendered to a sheet and looked at, and Windows 10's icon font has neither shape: the nearest translate glyph is E8C1,
a bare "A字", and the star and the globe that stood in for them at first read as other things. So
`drawBookmarkRibbon` is a five-point polygon and `drawTranslateTiles` two rounded rectangles with 文 and A in
Microsoft YaHei UI — the one face that has both and ships in every Windows 10 — all in `px()` units like the pips
and the profile dot. The GTK front keeps adwaita's star; that one was never measured against anything.

Measured by `PrintWindow` and a `WM_LBUTTONDOWN` sent from another process — the ribbon drawn hollow, filled after
a click, hollow again after the second, and gone along with the field after stepping to an empty workspace. The click
landing where the ribbon is drawn is also the check that matters at 150 %: the rectangle comes from `chromeLayout()`,
which paint and hit-test both read, so there is one place for the two to agree.

## The rail across a relaunch

Every profile's strip is written down after anything that changes its shape — a column opened,
closed, focused or moved, a page that went somewhere or got a title — rather than on quit, because a
browser that only saves on quit loses everything to the one crash it was going to have. It goes into
the `settings` table under `strip.state` as `StripState`: `NiriStrip` itself, the Mac's `Codable`
unchanged, plus each column's address and title. That type was the Linux front's; it is `SixCore`'s
now (`six/Persistence/StripState.swift`, compiled away on Apple, where `state.json` does this job), so
the two fronts write one shape under one key. `FileSnapshotStore` was the other candidate and lost
on the same argument Linux made: the database is already open, migrated, and where every other
preference lives.

Three things the profiles work had settled, and this keeps:

- **A strip per profile.** `NiriLayout.allStrips` is what is saved, so switching profiles loses
  nothing that was not on screen.
- **Which profile was on screen is `profile.selected`**, not a field of the snapshot. `StripState`
  still carries `activeProfile` because Linux reads it; this front writes it and never reads it.
- **The private profile is in none of it** — its strip, its addresses and its titles are filtered
  out before anything is written.

A strip whose profile has no row any more is dropped on the way in. `SIX_URL` still means something
over a restored rail: it opens one more column at that address, which is how a scripted run lands on
its test page whatever the previous run left. Measured by relaunching three times with a different
`SIX_URL` each: `[storage] restored 1 columns`, then `2`, each run adding its page beside the ones it
found.

## History

Visits go into the Mac's `visits` table through `SixCore`'s `HistoryStore` — under the column's own
profile rather than the one on screen, since a page kept live in another profile can still finish
loading. A private profile records nothing.

`didFinishNavigation` is the visit, and it is not the moment a title exists ("What the page says it
is, on a timer"), so the visit is written with whatever title there is and the column is marked as
awaiting one: the next title the poll reads is handed to the visit even when it is the title the card
already shows. That case is not hypothetical — it is every restored column reloading the page it was
on, and before this those visits were listed by their address.

**History** (`Ctrl+H`, or **⋯ ▸ History**) is a list window over it: type to search title and address,
`↑`/`↓` from the field, `Enter` or a double-click opens the row as a new column beside the focused
one, `Esc` closes. Empty is the recent pages, one row per address; anything typed is
`HistoryStore.search`.

## Live pages, discarding, and pictures

Every column the strip is showing, and half a screen either side of it, gets a real `WKView` —
`NiriLayout.visibleTabIDs`, the set the Mac's `LivePageCache` pins. Everything else lives or dies by
`LivePages` (about a page per gigabyte, 8…32, `SIX_LIVE_PAGES=n` to pin it): the Mac's rule, moved out
of the Linux front into `SixCore` so both run the same code. What this front hands it as "all" is every
column of every profile, so a hidden view of the workspace above survives while it is in budget; Linux
hands it the focused workspace, because that is all its strip widget builds.

A view out of sight is hidden, not destroyed, and stepping back to it does not reload. A view past the
budget is destroyed; its column keeps its place, title and address, and is built again from the
address when the strip reaches it. Measured with `SIX_LIVE_PAGES=2` on three columns: `[pages]
discarded …, 1 of 2 live` on the first step away, and the page back on the step back.

Clicking into a page that is not the focused column focuses its column. WebKit's child `HWND` takes the
click, so `route` sees the press on its way through the queue, focuses, and lets it go on to the page.

**Pictures.** A column that has no view — every column in the overview, and a discarded one — shows
the last picture of its page: `PrintWindow(PW_RENDERFULLCONTENT)` on the view's own `HWND`, the call
that already captured WebKit children for the harness, halved and kept as a 32-bit BMP at
`Thumbnails\<column>.bmp` (GDI writes and loads one with nothing but itself; the Mac and Linux keep
PNGs). A hidden view cannot be photographed, so pictures are taken on the way *out*: a moment after a
page finishes loading, just before a view is hidden or discarded, before the overview opens, and on
`WM_CLOSE`. A capture that comes back all zeros is a view that had not drawn yet, and is thrown away
rather than written over a good picture. The folder is pruned to the columns that exist at launch.

## The overview

`Alt+O`, or **⋯ ▸ Overview**; `Esc` leaves. It is the Mac's geometry point for point — each workspace a
row at `NiriLayout.rowY`, each row centred by `canvasX`, the whole canvas scaled about the window's
centre by `overviewScale`, which is what `.scaleEffect(_, anchor: .center)` does there — drawn in GDI
from `RailModel.overviewCards`, each workspace's name where its row begins. Every view is hidden while
it is open (a child `HWND` has no transform, and a page at a fifth of its size is neither sharp nor
useful), so the cards are the pictures above — which is also what the Mac draws there. A click on a
card focuses it and closes the overview, a click anywhere else closes it where it stood, and the wheel
needs no `Alt` — the Mac's scroll monitor drops its modifier in the overview for the same reason.

`⌥O` and `Esc` come out of `KeyBindings` like every other rail key. `Esc`'s row is scoped to the rail
rather than to the overview, so `RailKeyLookup` answers it only while the overview is open: a bare
`Esc` taken outside it would be taken from every page.

## Site permissions

The Mac's `SitePermissions`, out of `SixCore`: the remembered answers (the same `permissions.sites`
row the Mac writes), the queue per window, the suspended page, the private profile's answers kept in
memory. What this front adds is where a question comes from and where it is drawn:

- **`RailWebView.onMediaRequest`** — a `WKPageUIClientV6` with only
  `decidePolicyForUserMediaPermissionRequest` set (version 5 is where it arrived; every other callback
  is left `nil`, which is WebKit's own default for each). The origin is built from the
  `WKSecurityOriginRef` the way the Mac's `string(for:)` writes it, the request is retained until it
  is answered, the first device of each kind is what an allow hands over, and screen capture is
  denied rather than asked about as if it were the camera.
- **The bar** — `RailPermissionBar`, under the card's title, pushing the page down (`bodyRect(for:)`)
  so its **Block** and **Allow** are GDI's and not under a child `HWND`.
- **Site permissions** (**⋯ ▸ Site permissions**) — every remembered site, whose profile, what was
  answered; `Delete` forgets a row.

**No page can ask yet on this engine.** Playwright's WebCore has MediaStream compiled out:
`JSMediaStream`, `JSMediaDevices`, `UserMediaRequest` and `UserMediaController` appear nowhere in
`WebCore.dll` while `JSHTMLDivElement` does, and a page on `http://localhost` — a secure context — reads
`navigator.mediaDevices`, `MediaStream` and `RTCPeerConnection` as `undefined`, with
`WKPreferencesSetMediaDevicesEnabled` on and with the `MediaStreamEnabled` feature key set, both tried.
So the callback is wiring for the WebKit that is not Playwright's ([todo.md](todo.md)), and
`SIX_PERMISSION_SELFTEST=1` exercises everything past it: the first page to finish loading in the
focused column asks for the camera and the microphone through `RailModel.requestMedia` — the call the
callback makes — and the answer is logged under `[browser]`. `SIX_MOCK_CAPTURE=1` turns WebKit's mock
devices on, for an engine that has MediaStream to mock.

## The page's own dialogs

`alert()`, `confirm()`, `prompt()` and `<input type=file>` go through `RailWebView`'s UI client —
`runJavaScriptAlert`, `Confirm`, `Prompt` and `runOpenPanel`, all in the `WKPageUIClientV6` the media request
already used. Left `nil`, WebKit answers each itself and always says no: measured before this was written, a page
that put its answers in its title read `confirm=false prompt=null` with nothing on screen, and a file input never
opened — the browser that quietly cannot upload a file, which the Mac's `PageDialogs` exists to prevent.

- **The three dialogs** are `RailPageDialog`: an owned popup over the rail with the site in its caption
  ("example.com says"), OK and Cancel, and a field for a prompt with the page's default selected. `Enter` is OK and
  `Esc` Cancel, out of the queue through `route`, like the list windows. Not `MessageBoxW`: a prompt needs a field
  Windows has no box for, and a message box is a modal loop in which nothing drains the main queue, so every `Task`
  in the browser would stop with the one page that asked. One is on screen at a time and a second page asking
  waits (`waitingDialogs`). A column closed or discarded with a question up answers it Cancel, and so does closing
  the browser — `RailWebView.destroy` holds a Cancel for every listener it still owes, because the page's
  JavaScript is suspended inside each one.
- **The file picker** is `GetOpenFileNameW` — `SixRailOpenFiles` in `CRailInterop`, linked against `comdlg32` —
  opened one turn of the main queue after WebKit's callback rather than inside it, with the input's `accept`
  extensions as the first filter and everything as the second. **A folder (`webkitdirectory`) is refused for now:**
  that picker is COM's `IFileOpenDialog`.
- The log says what kind, from which site, how long and whether it was OK — never the text, never what was typed,
  never a path.

Measured end to end in an isolated run: an alert, a confirm answered OK, one answered Cancel, a prompt offering
`dflt` answered `typed` — the page's title came back `c1=true c2=false p=typed`; a click on a full-page file input
opened the picker as "This page is asking for a file", and choosing a file came back to the page as
`file=pick-me.txt n=1`. Keys were posted to the dialog's own window and the click to the
`WebKit2WebViewWindowClass` child, so none of it needed the foreground, and reading a control's text from outside
takes `WM_GETTEXT` — `GetWindowText` answers empty for another process's `EDIT`, which looked like a missing default.

**Test pages want a throwaway `LOCALAPPDATA`.** The rail comes back after a relaunch and `SIX_URL` adds a column to
it, so a test page from the last run is restored beside this run's and asks its questions too — two pages' dialogs
interleaved, which read as dialogs arriving in the wrong order. Starting `six-windows.exe` directly with
`LOCALAPPDATA` pointed at a fresh scratch folder gives it an empty database and an empty rail; the script cannot do
this for you, because it finds the toolchain through the same variable.

## A second window

The Mac's rule from [links.md](links.md): a window a page opened for itself comes forward, a link opened on
purpose goes behind with the focus left on the page being read, and both land right of the column that asked
(`RailModel.openColumn(url:from:focus:)`, over `NiriLayout.insertColumn(tabID:in:focus:)`). All of it is
`RailNewWindows.swift`.

- **`window.open` and `target=_blank`** reach the UI client's `createNewPage`, which is handed a view made on
  WebKit's own configuration (`WebEngine.makeView(parent:frame:configuration:)`) and returns its page at +1 — WebKit
  adopts it, which is why MiniBrowser's own `createNewPage` ends in `WKRetainPtr(page).leakRef()`. The page then loads
  its request into that view by itself. This is **better than the Mac**, which cancels the navigation and loads the
  address into a fresh column: here the new page is related to the one that opened it, so `window.opener` works and a
  sign-in popup can report back.
- **`window.close()`** reaches `close`, and the column goes. WebKit allows it only to a window a script opened.
- **A middle click or a `Ctrl`-click on a link** opens it behind; `Ctrl`+`Shift` opens it in front. WebKit's C API
  says nothing about the button or the keys behind a navigation — a `WKNavigationActionRef` has its request, its type
  and whether there was a gesture, no more — so the rail catches those clicks on their way in (`route`), against the
  link the page last reported under the pointer (`mouseDidMoveOverElement` → `RailWebView.hoveredLink`). The press
  and its release are both taken, so the page never sees half a click. A middle click the rail does not take goes to
  the page, and on this port that starts WebKit's **pan scrolling**, which then eats the next click — worth knowing
  before reading a test that "clicks and nothing happens".
- **A link to somebody else's app** — `mailto:`, `magnet:`, a claimed scheme — gets no column: a new one is made only
  for what a column can show (http, https, file, about, data, blob), and the rest is
  [Links to other apps](#links-to-other-apps).

Measured in an isolated run (`SIX_UI_DEBUG=1`, stderr to a file): a plain click on a page whose script called
`window.open('about:blank')` put a new column in front titled from the opener's script, the opener read
`w.opener === window` as true, and `w.close()` four seconds later took the column away — `popup=true opener=true`
on the page that was left, and `a page opened a window` / `a page closed its own window` in the log. A pointer moved
over a link reported `hover: link=data`, and a middle click there opened the link behind: two pages, the title still
the first page's, `a link opened behind` in the log. `Ctrl`-click is the same path and is unmeasured, because the
keys are read from the keyboard's state and a posted message cannot hold `Ctrl` down.

The first run of that test reported no link under the pointer at all, and the reason was the test: it hovered 400
physical pixels down a page that was not that tall. WebKit reports nothing past the edge of the view.

## Downloads

The transfer is WebKit's, which is the one place this front is simpler than the Mac. There, SwiftUI's `WebPage` has
no download delegate, so six rebuilds the request — cookies, referrer, user agent — and runs it through `URLSession`
([links.md](links.md#downloads)). The C API has downloads: `RailWebView`'s navigation client answers "download"
instead of "show" for `<a download>` (`WKNavigationActionShouldPerformDownload`) and for a response that is a file — an
attachment, or a type the page cannot show — and the `WKDownloadRef` that comes back through
`navigation…DidBecomeDownload` already carries the page's cookies. All `RailDownloads` adds is a client
(`WKDownloadClientV0`): where the file goes (`decideDestinationWithResponse`, a path handed back at +1), how far it
has got, and how it ended.

- **Where.** The user's Downloads folder by `SHGetKnownFolderPath`, not `%USERPROFILE%\Downloads`, which is only
  where it starts out. The call is made from Swift: declared in `WinSDK.Shell`, it is invisible to a C header in a
  module of its own, whatever that header includes. `SIX_DOWNLOADS=<folder>` stands in front of it, so a test run does
  not fill the real one. The name is the server's suggestion, made safe for Windows (no `\ / : * ? " < > |`, no
  trailing dot), and the Mac's `report 2.pdf` rule against both the files there and the ones other downloads are about
  to write. A `data:` link with no `download` attribute is suggested the tail of its own address by WebKit —
  `octet-stream,binary bytes`, measured — and comes down as `download` instead.
- **The button** appears in the bar with the first download, as the Mac's does, left of the translate button: an
  arrow, a thin bar under it while something is coming in, a dot in the profile's colour when something finished
  that nobody has looked at. It opens the list — a `RailListPanel`, refreshed as rows change — and so does `Ctrl+J`.
  `Enter` opens a finished file with whatever the system opens it with; `Delete` stops a download, or takes a row off
  the list and leaves the file alone.
- **A column that only carried the link** — a `target=_blank` or a middle click that turned out to be a file — closes
  itself and gives the focus back, the Mac's `closeIfOnlyCarriedALink`: `carriers` remembers who opened it, until the
  page in it finishes loading.
- **Not built, and why.** A stopped download stays stopped: `didFailWithError` hands back resume data and nothing in
  the C API takes it. There is no Try Again either — nothing starts a download from an address — and the unfinished
  rows are not written down for the next launch, since a restored row could offer nothing. A file small enough to
  arrive in one piece finishes without a single `didWriteData`, so the size of a finished row is read off the file.

Measured in an isolated run with `SIX_DOWNLOADS` pointed at a scratch folder: two clicks on a
`<a download="hello.txt">` link left `hello.txt` and `hello 2.txt`, nine bytes each; a middle click on a
`data:application/octet-stream` link opened a column behind that became a download, closed itself, and left one page;
a picture of the bar (`PrintWindow`, from a per-monitor-aware process) showed the arrow with its dot, and a posted
click on it opened the list with both rows, "Done · 12 B" and "Done · 9 B", the dot gone.

## A failed load and the loading line

**A page that did not open says so.** Left alone, a failed provisional navigation left the column exactly as it was —
blank, or the previous page — and silent about why, which is the report the Mac's `PageFailureView` was written
against. `RailWebView.handleFailedNavigation` puts the Mac's words in its place with `WKPageLoadAlternateHTMLString`:
"This page didn't open", the host, "six could not reach this address.", **Try Again** (a `location.replace` back to
the unreachable address), and the system's own sentence with its domain and code, demoted to the bottom. The call is
the one meant for it — the page is six's, the back-forward item and the address stay the unreachable one — and the
page's `<title>` is the host, so the card still says where it was going. `color-scheme` and system colours let it
follow Windows' light or dark. There is no certificate offer, because this front has no `CertificateStore` yet.

What is **not** a failure, and the two things measured to get there:

- The Mac's two: `NSURLErrorDomain` −999 and `WebKitErrorDomain` 101/102 — a cancel, and a policy that sent the
  request elsewhere (a download, a new window). Plus 203, a plugin taking the load.
- **`WebKitErrorDomain` 302, which is how this port says "cancelled".** Its network layer is curl, not `CFNetwork`,
  and a navigation superseded by another came back as exactly that. The first version did not know it, and the
  error page it put up cancelled the new navigation in turn: a page that went somewhere else while a slow address was
  still connecting ended on "This page didn't open" for an address nobody was waiting for any more.
- **Anything about a navigation that is no longer the latest.** The navigation client hands every callback its
  `WKNavigationRef`; the one that started last is remembered by address, and a failure of any other is ignored — it
  says nothing about what is loading now. This covers the cancel codes nobody has met yet.

A real failure measured for each kind: an address on a port WebKit refuses (`127.0.0.1:9`, `WebKitErrorDomain` 103,
"Not allowed to use restricted network port") and one where nothing listens (`127.0.0.1:65530`, `CurlErrorDomain`
7) both put the page up, titled `127.0.0.1`. The error page is not a visit and is not offered for translation
(`isShowingFailure`), and the sandbox views never get one (`showsFailures`): their pages are six's own programs, and
a failure there is their driver's to see. The log keeps the domain and the code, never the address.

**The loading line** is the Mac's `LoadingLine`: two pixels in the profile's colour, never shorter than a sliver,
under the address field for the window being read and along the foot of the card's header for every other one.
`isLoading` comes from the navigation client (started → finished or failed), the progress from
`WKPageGetEstimatedProgress` on the page-state timer that already polls titles, in steps of a twentieth so a page
trickling in repaints a handful of times. Measured against a local server that sent a page in twelve pieces over six
seconds: a picture of the bar half-way through shows the line about half the field's width, and one after shows none.

**Stop.** While the page being read is loading, the bar's reload button draws a cross and stops the load
(`WKPageStopLoading`) — the Mac's Reload-or-Stop. It changes with `isLoading`, which the page-state timer already
repaints on. The cancel a stop causes comes back through `didFailProvisionalNavigation` as a failure that is not one
(the list above), so stopping a page never puts "This page didn't open" in its place.

## The context menu

The menu over a page is **WebKit's**, and on this port that is a real menu. Read off the one a right-click put up
(`MN_GETHMENU` on the `#32768` window, then the menu's own strings): over a link it offers Open Link, Open Link in New
Window, Download Linked File and Copy Link; over plain text on a fresh page, Reload and nothing else. The Mac had to
throw WebKit's menu away and build its own ([links.md](links.md#the-context-menu-is-sixs)), because in a SwiftUI
`WebView` two of those four are dead — they go to a UI client and a download delegate that API has no seat for. Here
they are alive: Open Link in New Window reaches `createNewPage` ([A second window](#a-second-window)), and Download
Linked File reaches the navigation client's `contextMenuDidCreateDownload`, which hands it to `RailDownloads` like any
other download.

So the menu stays WebKit's, and six adds the one item of the Mac's it lacks: **Open Link Behind**, right after Open
Link in New Window. It goes in through `getContextMenuFromProposedMenu` (`WKPageContextMenuClientV2`), which hands over
WebKit's items and the hit test the menu was opened on; the link is read then, because by the time an item is chosen
the pointer has moved. Its tag is above `kWKContextMenuItemBaseApplicationTag`, so WebKit hands the choice back
through `customContextMenuItemSelected` rather than acting on it, and it ends in `openLink(_:from:focus:)` — the same
place a middle click does. The array handed back is WebKit's to adopt, and handing back nothing is not "use your own":
it is an empty menu, so the proposed items always go back, with or without the addition.

Measured in an isolated run, each item chosen with the keys a person would press (`↓` to it, `Enter`, posted to the
menu's window): Open Link Behind opened a column behind with the first page still in focus; Download Linked File left a
file in the downloads folder; Copy Link put the link on the clipboard; Open Link in New Window opened a column in
front.

Not offered, and why: the Mac's **Open Link Beside**, because nothing on this front makes a window share its column
yet; and its **This Window** submenu, the column's own commands.

## Links to other apps

`mailto:`, `magnet:`, `tel:`, whatever an app claimed. Which addresses these are is `ExternalScheme` — the Mac's list,
moved into `SixCore` for this (`six/Browser/ExternalScheme.swift`), because a second copy of an allowlist is a second
chance to let a scheme through. It needed the two MCP-app scheme names with it, so `MCPAppScheme` is now declared in
`MCPAppTypes.swift`, the wire half, and extended in `MCPAppScheme.swift`, where the WebKit-facing handler stays.

**Every route asks the same question.** The navigation client takes any navigation to such an address away from the
page (`decidePolicyForNavigationAction` → `RailWebView.handOff`): a click in place, a script, an `<iframe>`. So does
`createNewPage`, so a `target=_blank` to one makes no column; so does a middle or `Ctrl`-click on one. All of them end
in `offerExternalLink`.

**Asked, and only after a click.** The Mac hands these to the system on a click without asking. Windows is not the
same place: a protocol handler opened without a question is how `ms-msdt:` became an exploit, and every Windows
browser asks. So:

- no user gesture behind it (`WKNavigationActionHasUnconsumedUserGesture`) — refused, and a line in the log;
- an app claims the scheme — "Open this link in *Mail*?", the name from `AssocQueryStringW` with
  `ASSOCF_IS_PROTOCOL`, which honours the default picked in Settings; OK hands the address to `ShellExecuteW`;
- the scheme is Windows' own and nobody was picked for it — measured on this machine for `mailto:`, where the
  "app" Windows names is its own picker ("Choose an app", in the system's language) because what would run is
  `OpenWith.exe` — "Open this link in another app? Windows will ask which one.";
- nothing claims it — a sentence that says so, and nothing else.

The log keeps the scheme and the app, never the address. The address bar is left alone: typed text with a scheme and
no `://` is a search on this front, which is the safe reading of `note: buy milk`.

Measured in an isolated run, every question answered Cancel so that nothing was launched: a page's own
`location='ms-settings:display'` a second after it loaded was refused with nothing on screen; a click and a middle
click on a `mailto:` link each asked, as the picker case; a click on a `magnet:` link, on a machine with no torrent
client, said no app opens those; the page never navigated.

## The list windows

History and Site Permissions are one type, `RailListPanel`: an owned popup window — a frame of its own,
movable off the page it is about — with an `EDIT` to search in and an owner-drawn `LISTBOX`, because a
list box's own rows are one line of system text and a visit is two things. Its keys come out of the
queue through its own `route`, which `RailWindow.route` asks first, since an `EDIT` and a `LISTBOX`
each have their own idea of `Enter`, `Esc` and the arrows. Its caption is the system's, and on Windows
10 that is a light title bar over a dark list; `DWMWA_USE_IMMERSIVE_DARK_MODE` would fix it and was
not reached for.
