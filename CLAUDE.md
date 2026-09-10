# CLAUDE.md

Working notes for whoever changes this code. [README.md](README.md) is the pitch, [docs/](docs/) is the reference;
this file is the part that is neither — how to build it, how to check it, and the things that have cost hours.

## What six is

A browser with a [niri](https://github.com/YaLTeR/niri)-style scrollable-tiling layout: no tabs and no sidebar, a page
is a full-height **window** on a horizontally scrollable **rail**, a rail is a **workspace**, workspaces stack
vertically. Four front ends over one core:

| | | |
|---|---|---|
| **macOS** | `six.xcodeproj`, scheme `six` | where every feature lands first |
| **iOS/iPadOS** | `six.xcodeproj`, scheme `six-iOS` | same `six/` folder, exclusions in the pbxproj |
| **Linux** | `linux/`, SwiftPM + GTK4/WebKitGTK 6.0 | over the same `six.sqlite`, in a container |
| **Android** | `android/`, Kotlin + Compose | system WebView, its own storage layer, [docs/android.md](docs/android.md) |
| **Windows** | `windows/`, SwiftPM + Win32 (`WinSDK`) | real WebKit2 engine, with a DPI shim in front of it — [docs/windows.md](docs/windows.md) |

Built on the macOS 26/27 APIs on purpose: SwiftUI `WebView`/`WebPage` (no `NSViewRepresentable`), Foundation Models as
the single LLM API, ACP for agents, and the browser itself as an MCP server. Swift 5 language mode, `@Observable`,
`@MainActor`.

## Where things are

```
six/Niri          NiriLayout (workspaces, columns, geometry, focus/move), NiriScrollMonitor (⌥+scroll gestures)
six/Input         KeyBindings + KeyContext (the table, in SixCore), KeyEvents (the AppKit half), KeyRouter, KeySelfTest
six/Browser       BrowserState, BrowserTab (WebPage), Profile/ProfileStore, History, SearchEngine, LivePageCache,
                  SitePermissions, CertificateStore, Downloads, IDN, PersonalSuggestions, PageThumbnails
six/Views         ContentView (top bar), NiriStripView (rail + overview), StartPage, SettingsPageView, AssistantBar,
                  AgentPanel, MCPApps*, Phone/ (the iOS layout)
six/Data          AppSupport (the one place that knows the bundle id → folder), AppDatabase, SettingsStore
six/Persistence   AppStateSnapshot, SnapshotStore (versioned JSON), StatePersistence (debounced autosave)
six/Bookmarks     Bookmark(Store), ReadablePage (Markdown copy), Embedder/MLXEmbedder (on-device, multilingual-e5)
six/Blocking      ContentBlocker (WKContentRuleList per profile), FilterList(Store), RuleConversion,
                  AdvancedRules (scriptlets + extended CSS, in the page), Payload/ (built JS)
six/Extensions    ExtensionStore (a controller per profile), ExtensionInstaller + the compatibility verdict
six/Translation   the portable half (segments, batching, the page script, LanguageGuess) + AppleTranslator
                  on Apple and Bergamot/ — Marian as wasm in an off-screen page — on Linux and Windows
six/ACP           JSONRPCConnection, ACPClient (actor), ACPAgent (process), AgentSessionStore (view model)
six/MCP           MCPServer + MCPSocket + MCPStdioBridge (`six --mcp`), Client/ (MCP apps, SEP-1865, OAuth, catalog)
six/Tools         BrowserTools — one catalog, served to the assistant, to ACP agents and over MCP
six/Vendor        ClaudeForFoundationModels, FoundationModelsUtilities — compiled into the target, see below
```

`SixCore` (root `Package.swift`) is the slice that must build on **Linux**: `NiriLayout`, the storage layer, the
profile/bookmark/permission/translation models, the key bindings, and the wire half of ACP/MCP. A file joins it by
being listed in `sources:` — see the essay at the top of that manifest before editing it.

New files under `six/` need no project edits (`PBXFileSystemSynchronizedRootGroup`), but a file that must **not** ship
on iOS needs a line in `membershipExceptions` in `project.pbxproj` — a bare folder name there does not recurse.

## Build

```sh
# macOS — both skip flags are required (SQLiteData macros, mlx-swift's CudaBuild plugin)
xcodebuild -project six.xcodeproj -scheme six -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation build

# iOS — a destination, never -sdk iphonesimulator (that breaks every @Table macro)
xcodebuild -project six.xcodeproj -scheme six-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation build

# SixCore and its tests — ALWAYS with the flag, on every invocation
swift build --disable-automatic-resolution
swift test  --disable-automatic-resolution

./scripts/dmg.sh          # Release → dist/six-<version>.dmg

# Vendored JavaScript. Both write committed output, so a normal build needs neither network nor
# Node; run one only when the upstream version it pins moves.
./scripts/blocking-payload.sh     # AdGuard's scriptlets and extended CSS → six/Blocking/Payload
./scripts/bergamot-payload.sh     # Emscripten's glue for bergamot-translator → six/Translation/Payload
```

Details, and the SDK override, in [docs/build.md](docs/build.md).

### The Linux front

**Run it only when the work is about Linux, and say so before starting one.** The container is the heaviest thing
this machine does: a cold `six-linux.sh core` is **17 minutes** at 4 GB on a Mac that has 8, and everything else on
the desktop swaps for the duration — the three-minute figure below is a *warm* scratch path. A Swift change that
compiles on the Mac does not need proving on Linux unless it touches something the two platforms spell differently:
`Foundation` against `FoundationNetworking`, paths, processes, threads, a manifest, or a pin. Those are the cases,
plus a version move ([above](#three-fronts-one-dependency-graph)). Everything else waits for a session that is about
the Linux front, and `swift build --disable-automatic-resolution` on the Mac is the check in the meantime.

It is built and run **in a container** — never on the Mac, and `swift build --package-path linux` on macOS cannot
work, because `CWebKitGTK` has no `webkitgtk-6.0` to resolve against. Apple's own `container` CLI runs it natively on
Apple Silicon, and the system service has to be up first (`container system start`).

All of it is [`scripts/six-linux.sh`](scripts/six-linux.sh) — the recipe used to live in scripts written into the
container's own filesystem, so it died with every container and was rebuilt from memory each time:

```sh
./scripts/six-linux.sh image        # build six-gnome:26.04 from linux/Containerfile
./scripts/six-linux.sh up           # start six-live, then open the URL it prints
./scripts/six-linux.sh build fresh  # rebuild inside it; `fresh` also drops the cached build plan
./scripts/six-linux.sh test         # SixCore's tests, on Linux
./scripts/six-linux.sh core         # SixCore alone in a plain toolchain image — the pre-version-bump check
./scripts/six-linux.sh shot out.png # one still picture, no VNC
./scripts/six-linux.sh logs / sh / down
```

`up` runs [`scripts/linux-run.sh`](scripts/linux-run.sh) inside the container: it builds, then starts `Xvfb :99`, the
binary at `/tmp/g/debug/six-linux`, `x11vnc` and `websockify`, so the window is **watchable in a browser at
`http://localhost:6080/vnc_lite.html`**. There is no display in a container; this is how the Linux UI gets looked at.
The app runs under a restart loop on purpose — a front that has crashed and a front drawing nothing are the same black
screen, and a restart at least says *when*.

Three things that cost real time, all of them now handled by those two scripts — the reason to know them anyway is
that they apply to anything else you run in there:

- **Never pipe the build into `grep`.** `swift build … | grep -E "error:|Build complete"` makes a *failed* build exit
  0 through a successful grep, `set -e` never fires, and the supervisor cheerfully relaunches the **previous** binary
  — several rounds of "it still crashes" were one stale crash. Build into a log, check the exit code, then grep the
  log.
- `--cpus 2 --memory 4g`, and `-j 2`. The default 1024 MB stalls with no error and no output ([above](#three-fronts-one-dependency-graph)), and this Mac has 8 GB to share with everything else.
- The scratch paths are conventions, and the `build.db` rule above is about *these two*: `/tmp/g` for the GTK front,
  `/tmp/gcore` for the root package's tests. `build fresh` is what drops them.

What the front does and does not have, the GTK traps (a `Task` never runs under `g_main_loop_run`; every signal has
its own C signature; only value types in `@State`), and the run-time environment variables — `SIX_URL`,
`SIX_LIVE_PAGES`, `SIX_UI_DEBUG`, `SIX_MOCK_CAPTURE` — are in [docs/linux.md](docs/linux.md).

### The Windows front

```powershell
./scripts/six-windows.ps1 build   # compile, copy the runtime DLLs next to the .exe
./scripts/six-windows.ps1 run     # stop what is running, build, launch exactly one
./scripts/six-windows.ps1 stop    # stop what is running, nothing else
```

Built on the Windows dev machine itself, not in a container, and all three are idempotent — `run` twice leaves one
window, not two. The script exists because a plain `swift build` in `windows/` needs the MSVC linker and the
toolchain's own `bin` directories on `PATH`, and the Universal CRT, Swift runtime and WebKit DLLs copied next to the
`.exe`. `SIX_URL` and `SIX_UI_DEBUG` work here the way they do on Linux, and `SIX_URL` is the only way to point a run
at a test page when nobody is at the keyboard.

**It builds with `6.3.3+NoAsserts`, and that is load-bearing.** `swift-structured-queries`, which arrives through
SQLiteData, trips a constraint-solver *assertion*, so the `+Asserts` toolchain — the one swift.org's installer puts on
`PATH`, and for a long time the only one anybody here knew about — cannot build this front at all. The same installer
carries the release compiler and just does not install it: re-run it as
`swift-6.3.3-RELEASE-windows10.exe OptionsInstallNoAssertsToolchain=1` and it lands beside `+Asserts`, replacing
nothing. The script defaults to it and says this if it is missing. Two more things it arranges by itself, both once
and both cached: the SQLite amalgamation (Windows has no system `sqlite3.h`, so GRDB will not build without it) and a
sibling clone of `combine-schedulers` with `windows/patches/`'s SRWLOCK patch applied, substituted through SwiftPM's
mirror mechanism. `windows/.swiftpm/configuration/mirrors.json` is generated and gitignored — SwiftPM takes only an
absolute path for a mirror.

The engine is not a Swift package: it is whatever `playwright install webkit` put under `%LOCALAPPDATA%\ms-playwright`,
and `windows/vendor/WebKit2` holds only the import library generated from that DLL's export table. Node for that
installer is a user-scope unzip at `%LOCALAPPDATA%\six-tools\node-*`, deliberately off `PATH`.

Everything else — why Win32 and not WinUI, the DPI shim, the top bar and the profiles behind it, and what is
still missing — is in [docs/windows.md](docs/windows.md).

## Running and checking a change

The fresh app is in DerivedData, **not** in the repo's `build/`:

```sh
ls -td ~/Library/Developer/Xcode/DerivedData/six-*/Build/Products/Debug/six.app | head -1
```

- Debug is `org.deffun.six.dev` ("six dev"), Release is `org.deffun.six`. **They coexist and are meant to** — the
  Release one is Artem's real browser with real state. Never kill it; restart only the dev one, by its own id.
- `pkill -x six` + `open -na <full path>`. Never `open -b <bundleid>`: with several copies registered, LaunchServices
  picks whichever it likes and two sixes on one Application Support directory trap in WebKit.
- Launch from a non-sandboxed shell (`dangerouslyDisableSandbox`), or the app never initialises. A crash in
  `sixApp.init` leaves no window and no stderr — run the binary directly once, or read `~/Library/Logs/DiagnosticReports/six-*.ips`.
- **six keeps a log now, and it does not need a terminal**: `~/Library/Logs/org.deffun.six.dev/six.log` for the dev
  build, plus the unified log (`/usr/bin/log show --last 1h --info --debug --predicate 'subsystem ==
  "org.deffun.six.dev"'` — `log` alone is a zsh builtin and dies with "too many arguments"). Everything that used to
  be an unread `[six] …` on stderr is in both. [docs/logging.md](docs/logging.md).
- Before believing "it's still not there", check `ps -eo pid,lstart,command | grep MacOS/six`. Three rounds of that
  once turned out to be a stale Release build being looked at.

**Screenshots do not work here.** `screencapture` writes black (no Screen Recording for the terminal) and System Events
is refused (no Accessibility), so synthetic clicks, hover and menu states cannot be captured. Verify through six's own
MCP server instead — that is what it is for:

```sh
<six.app>/Contents/MacOS/six --mcp     # JSON-RPC on stdio, relays to the running app over its Unix socket
```

`open_window` with a `six://` address, `list_workspaces`, `get_page_content`, `evaluate_javascript`,
`list_console_messages`, `take_screenshot` (only for windows with a real `WebPage`). See [docs/mcp.md](docs/mcp.md).

**Keys can be pressed, though — `NSApp.postEvent` needs no Accessibility.** It is the app's own queue, and a local
`NSEvent` monitor is exactly what pulls events out of it, so a synthetic `⌥→` goes through the real router and moves
the real rail. `SIX_KEY_SELFTEST=1` does both halves: it prints what every binding answers in every context, then
posts the rail's keys one at a time and says where the rail ended up (`six/Input/KeySelfTest.swift`). It does the
`⌘` keys too, which are menu items and not table rows: `menuKeys` makes the focused `WKWebView` first responder by
hand and then posts `⌘[` `⌘]` `⌘R`, because the interesting case is the one where WebKit is in front of the menu bar.
Add to it rather than reasoning about the keyboard from the source — the bug it was written to find had survived a
whole session of reasoning. Two things that make its output readable: a **control** key whose effect is not in doubt,
so "the item did nothing" can be told from "the key never arrived"; and that control going **last**, because `⌘T`
takes the selection with it and every key after it is then aimed at a fresh window with no history — which reads
exactly like WebKit swallowing the key, and was believed once. `SIX_UI_DEBUG=1` prints a line per key press with the context it landed in and who took it.

## Three fronts, one dependency graph

This is where the repository bites most often: a version moves in one place and a *different* front stops building.
Read this before touching any manifest, `Package.resolved`, or the `sources:` list.

**There are four resolved graphs, and they are not independent.** The Windows one is new, and used
not to exist: `windows/Package.swift` had no package dependencies at all, because depending on the
root package dragged in `swift-structured-queries`, which crashed `swift-frontend` there. That was
read as a Windows compiler bug for a long time. It is not — it is an *assertion*, and Windows is the
one platform where swift.org ships the assertions-enabled compiler; the same source builds on macOS
and Linux because those toolchains are release builds. The `+NoAsserts` toolchain the same installer
carries compiles the whole graph, so the Windows front now depends on `SixCore` like every other
front, and has a resolved file to keep in step. docs/windows.md has the account.

| file | resolves for | the constraint on it |
|---|---|---|
| `six.xcodeproj/…/swiftpm/Package.resolved` | the Mac and iOS app | the leader — the app's graph moves first |
| `Package.resolved` (root) | `SixCore` + its tests, on **both** platforms | a **superset** of the app's, and the surplus is the point |
| `linux/Package.resolved` | the GTK front, which depends on the root by path | must agree with the root on the shared subset |
| `windows/Package.resolved` | the Win32 front, which depends on the root by path | the same, plus `combine-schedulers` held at the version the local mirror carries |

The asymmetry is the whole rule: the app's graph leads on **versions**, but the root file holds pins the app has never
heard of — `opencombine` appears once there and zero times in the app's, because only Linux pulls it in. A resolve run
on a Mac cannot know that, which is why it deletes it.

They must agree on **GRDB, sqlite-data, swift-structured-queries** above all, because a database written by one build
is opened by the other — a schema written by GRDB 7.11 and read by another version is the one failure that costs data
rather than time. They currently sit at GRDB 7.11.1 / sqlite-data 1.11.0 / structured-queries 0.37.0 everywhere. A
fresh resolve does **not** land on them by itself — the Windows file's first one came out at sqlite-data 1.13.0 and
structured-queries 0.39.2 — so a new resolved file gets walked back with `swift package resolve <package> --version`
before it is committed, one package at a time, and read back to check.

Windows is the one deliberate exception, and only outside those three: it holds `swift-sharing` at **2.10.1** where
the others hold 2.9.1, because sqlite-data 1.11.0 asks Sharing for an `IdentifiedCollections` trait that 2.9.1 does
not declare, and the resolver refuses the pair outright. Sharing writes nothing to the database, so this costs
nothing that the rule above is protecting. That the other three graphs *do* resolve at 2.9.1 is a good illustration of
the warning further down: `--disable-automatic-resolution` means their pins have not been re-checked against their
manifests in a while.

**Why the pins are frozen, in three sentences.** sqlite-data 1.11.0 does not compile against structured-queries 0.38,
so a free resolve picks a set that builds nowhere. swift-sharing 2.10.0 imports `Foundation.NSData` — a Clang
submodule that does not exist on Linux — and combine-schedulers 1.2.1 uses `pthread_mutex_t` without importing
CoreFoundation; both arrive through SQLiteData, which depends on Sharing unconditionally even though six uses none of
it. Both are regressions, both are written up with repros in [UPSTREAM.md](UPSTREAM.md), and until they are fixed
upstream the only defence is the pin.

**So: `swift package update` is a Linux-breaking command in this repo.** So is a plain `swift build` or `swift test` —
they resolve first, and a resolve *on macOS* silently rewrites the root file: the `originHash` changes, the
`opencombine` pin is dropped, and `swift-issue-reporting` appears in its place. Pass `--disable-automatic-resolution`
to **every** `swift build` / `swift test` here, including the one inside the container — even `swift test --help`
triggers the rewrite. `--skip-update` is not the same flag; it skips the fetch and still writes.

**`xcodebuild` is not the culprit.** The Xcode project holds only remote package references and no
`XCLocalSwiftPackageReference` at all, so it cannot see the root `Package.swift`: it resolves into the app's own file
and leaves the root one alone. Blame `swift build` / `swift test`, and only those.

**How to spot the damage**, since nothing fails at the time — and the tell is the *missing pin*, not the hash:

```sh
grep -c opencombine Package.resolved     # must be 1
git checkout -- Package.resolved         # the answer whenever it is 0
```

The committed state is the one with `opencombine` (originHash `cf9bc021`, last written by `04e3e70`). This has
flip-flopped in history — `25da59a` committed the macOS shape, `ae4ca3a` put `opencombine` back — so if the file is
dirty and nobody claims it, it is a stray resolve, and the answer is `git checkout`, never a commit.

**The flag will fail on a cold build, and that failure is the flag working.** This is the trap that has produced every
flip-flop, so read it before you conclude the flag is broken. The root package genuinely resolves to *different* pin
sets on the two platforms: macOS wants `swift-issue-reporting`, Linux wants `opencombine`, and one file cannot hold
both. The committed file is the **Linux** shape. So whenever SwiftPM actually has to run the resolver on a Mac — a
fresh clone, a cleaned `.build`, a new worktree — the flagged command stops:

```
error: an out-of-date resolved file was detected at …/Package.resolved, which is not allowed when
automatic dependency resolution is disabled; … Running resolver because the following dependencies
were added: 'swift-issue-reporting'
```

Measured at `ca47ef6`, in a throwaway worktree, `Package.resolved` md5 checked after every run — the untouched file
is `47a22feb`, and three sessions reached this table from three separate worktrees, so it is settled and does not want
re-testing:

| scratch path | flag | result | the file |
|---|---|---|---|
| cold | `--disable-automatic-resolution` | exit 1, the error above | **byte-identical** |
| warm | `--disable-automatic-resolution` | exit 0, builds | **byte-identical** |
| either | *none* | exit 0 | `opencombine` gone, `swift-issue-reporting` in |

Two things follow. A **manifest edit is not the trigger** — the error fires on a pristine manifest, and it fires
because the macOS graph differs, full stop; do not go looking for what you changed. And the reason the flag usually
seems to work is that a warm `.build` already holds a satisfying workspace state, so no resolve is attempted at all —
which is why this only bites on the machine that just cleaned its build directory. The corollary is the useful half:
**a green flagged build is not evidence that the pins satisfy the manifest**, only that no resolve ran. The two rows
above differ in nothing but the scratch path. So a warm build will also happily build against pins that no longer
reflect an edited `Package.swift`, and say nothing about it.

What not to do: take the flag off to get past it. The command then succeeds, and *that* is the commit that kills the
pin. The file is not out of date for the platform it was written for. Build with a warm `.build`, or accept the error
and leave the file alone; if `SixCore` genuinely has to be built cold on the Mac, restore the file afterwards
(`grep -c opencombine` back to 1) before committing anything.

Whether the root file should stay the Linux shape, or the Mac should be given a resolved graph of its own, is an open
decision and not something to settle mid-task.

**When a version genuinely has to move** — a real upgrade, not an accident:

1. Move the **app's** graph first, in Xcode, and build both Apple schemes.
2. Reconcile the root file to the app's versions by hand for the shared packages; keep `opencombine`.
3. Prove `SixCore` still builds on **Linux** before committing — that is the only step that catches Linux-only
   breakage, and it has already caught one (`URLSession` and `HTTPURLResponse` live in `FoundationNetworking` there,
   which nothing on macOS can tell you):

```sh
container run --rm --memory 4g -v "$PWD:/work" -w /work docker.io/library/swift:6.3.3-noble \
  bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends libsqlite3-dev >/dev/null \
           && swift build --disable-automatic-resolution --scratch-path /tmp/linuxbuild -j 2'
```

The plain toolchain image has **no `libsqlite3-dev`**, so GRDB dies on `'sqlite3.h' file not found` before `SixCore`
is reached; and `container run` defaults to 1024 MB, at which the build stalls around 120/453 with no error and no
progress for as long as you leave it. With `--memory 4g -j 2` it is three minutes onto a warm scratch path and
seventeen onto a cold one — which is why this is the version-move check and not a habit ([above](#the-linux-front)).

**The other direction — breaking the Mac from the Linux side.** The root `Package.swift` is compiled on both, so
anything added there has to exist on both:

- **No sqlite-vec in the root manifest.** Its `CSQLiteVec` reads the system SQLite headers while adwaita-swift's
  `meta-sqlite` vendors its own, and Clang refuses two definitions of `sqlite3_api_routines` in one compilation unit.
  `AppDatabase` asks for it with `#if canImport(…)` so the app keeps vectors and the Linux build does without. The
  same reason keeps `SixBrowser` free of Adwaita in `linux/Package.swift` — the seam is enforced by the compiler, not
  by discipline.
- **A file joins `SixCore` by being listed in `sources:`** — and from that moment it is compiled on Linux. Anything
  Apple in it needs `#if canImport(WebKit)` / `#if os(macOS)`, and networking needs
  `#if canImport(FoundationNetworking) import FoundationNetworking`.
- **Editing the root `Package.swift` does not reach the Linux build, and the symptom is a *success*.** llbuild caches
  the whole build description in the scratch path's `build.db`, keyed on the manifest it was planned from, and a
  *path*-dependency edit does not bump that key: `swift build` prints "Build complete!" in a tenth of a second and the
  file you just added is never compiled. `rm -f <scratch-path>/build.db` after any manifest edit — `/tmp/g/build.db`
  for the GTK front, `/tmp/gcore` for the root package's own scratch, which `swift test` uses. Object files survive,
  so the rebuild is incremental. Clearing `~/.cache/org.swift.swiftpm/manifests` does **not** help.
- **WebKitGTK cannot be brewed on the Mac** — `depends_on :linux`, and brew's formula is GTK3 / WebKitGTK 4.1 anyway,
  while six needs the GTK 4 `webkitgtk-6.0` API. The Linux front stays in the container; the full checked list is in
  [docs/linux.md](docs/linux.md#why-the-container-and-not-homebrew-on-the-mac) so it does not get retried every few
  months.
- **The container tracks GNOME, not convenience.** adwaita-swift's `main` follows GNOME 50, so `linux/Containerfile`
  is Ubuntu 26.04 (GTK 4.22): on 24.04 adwaita's own C shim will not compile, on 25.10
  `gtk_picture_set_isolate_contents` is still missing. adwaita-swift itself is pinned to a **commit**, because its
  only tag does not build on Linux. Moving any of those three is a deliberate act with a rebuild behind it.

## Things that have cost hours

- **The SDK override is load-bearing.** The target sets `SDKROOT` to the *Command Line Tools* macOS 27 SDK because
  Xcode's own SDK has an older Foundation Models executor ABI than the OS and crashes third-party `LanguageModel`s on
  launch. That is also why `six/Vendor/` exists: a SwiftPM target would ignore the override. Don't move those back to
  packages until Xcode's SDK matches.
- **The app target compiles main-actor-by-default** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so anything that
  does not say `nonisolated` is on the main actor — and the compiler complains at the *reader*, not at the
  declaration: a `static let` holding a path becomes a warning inside the detached save three files away. Say
  `nonisolated` as the code is written, on what is read off the main actor — pure value work (paths, hashing, wire
  decoding, an extension on `Data` or `Color`), the constants a background closure reads, and every top-level
  declaration of a vendored tree, which was written for a package where nothing is isolated unless it says so. And a
  non-Sendable value cannot cross an isolation line at all: `MainActor.assumeIsolated` handing back an `NSEvent` is a
  warning, handing back the verdict about it is not. Eighty-seven of these had accumulated by `09dd84c`; a build that
  prints nothing is the state worth keeping, because a build that prints eighty-seven is one nobody reads.
- **A `Task` does not run on the Linux or Windows front unless something drains the main queue.**
  The main actor's executor on both is libdispatch's main queue, and a thread parked in
  `GetMessageW` or inside `g_main_loop_run` never drains it: the task is enqueued and then simply
  never executed, with nothing said. Measured with a standalone probe on Windows before anything was
  built on it. The fix is the seam CoreFoundation uses — `_dispatch_get_main_queue_handle_4CF` for a
  waitable handle, `_dispatch_main_queue_callback_4CF` to drain on the calling thread — wired into
  the platform's own wait: `RailLoop` on Windows, `MainQueueBridge` + `g_unix_fd_add` on Linux.
  `swift_task_enqueueMainExecutor_hook` looks like the answer and is never called any more;
  SE-0463's `ExecutorFactory` is the answer and is not in 6.3.3.
- **`FileManager.replaceItemAt` is a `fatalError` on Windows, not a thrown error.** The obvious call
  for "verified file, atomic swap"; `try?` in front of it catches nothing, and it took the browser
  down the first time a translation model finished downloading. Remove-if-present plus `moveItem`.
  `.libraryDirectory` on Windows answers with an *empty array*, which is the same shape of trap one
  subscript along — `AppSupport.logs` spells Windows out for that reason.
- **`WebPage.callJavaScript` is not `callAsyncJavaScript`** — an `await` in the body fails at parse time with a bare
  "A JavaScript exception occurred". Page scripts stay synchronous; poll from Swift for anything that must wait.
- **sqlite-vec on Apple's SQLite** works only per connection (`sqlite3_vec_init` from GRDB's `prepareDatabase`);
  `sqlite3_auto_extension` returns MISUSE. The e5 embedder needs `Pooling(strategy: .mean)` set explicitly.
- **Sizes are fractions of the viewport, not point constants.** Artem is on a 5K display; a constant tuned on a laptop
  becomes a hairline there. Absolute numbers are fine only as floors/ceilings and for control metrics.
- **The dev Mac has 8 GB** and usually sits in macOS's `.warning` memory-pressure band already. Anything sized per GB
  lands at the bottom of its range; `.warning` paths are the normal case, not the edge case.
- **Never delete a credential or hard-to-recreate state file** to reproduce a first-run path. Copy it aside, or point
  the program at a throwaway config root.
- **`event.modifierFlags` carries more than the hand does.** macOS puts `.function` **and** `.numericPad` on every
  arrow key, and `.capsLock` on everything while Caps Lock is down; `deviceIndependentFlagsMask` keeps all three. So
  `flags == .option` is false for `⌥→` and always was — the rail's arrow keys had never worked from the keyboard, and
  the report they finally arrived as was "option + arrow doesn't always work". Compare against
  `KeyBinding.Modifiers.held` (⌘⌃⌥⇧) and nothing else.
- **A `.disabled` on a SwiftUI `Commands` item is decided once, and a disabled item eats its key
  equivalent.** The body is not rebuilt when the model state it read changes, so `Back` greyed out on
  `canGoBack` stayed greyed out after a navigation and `⌘[` did nothing at all — measured with a run
  each way. Read the window *inside* the action and let the key be a no-op where it has nothing to
  do; `.disabled` on a `@FocusedValue` is the one form that does get rebuilt.
- **A letter binding read from `charactersIgnoringModifiers` is a binding that only Latin layouts have.** `⌥W` reports
  «ц» on the Russian layout. Match the key code as well (`KeyBinding.Key.letter`), which is what a tiling WM does.
- **On Windows, how a page is drawn and where its clicks land are one problem, and the fix is a window procedure.**
  Playwright's WebKit deletes the `/ intrinsicDeviceScaleFactor` from `WebView::onSizeEvent` (their public
  bootstrap.diff), so the view size stays physical while rendering still multiplies by the scale — nothing reachable
  from the C API can undo it, because the damage is done before any of those knobs are read. `RailWebView.installScaleShim` divides `WM_SIZE` by the display scale, which lands the product on the
  window's real pixels. It must **not** touch mouse messages: WebKit already divides those by the device scale, and
  doing it twice put every click 1.5× out. Measure with a page that writes `innerWidth`/`devicePixelRatio` into its
  own title and a labelled grid clicked by hand — reasoning about this produced three confident wrong answers in a
  row, including one that shipped. [docs/windows.md](docs/windows.md).
- **A Windows process that has already stopped can still hold the build directory.** Zero threads, no image path,
  `taskkill` answering "Access is denied", outliving the session that made it and clearing only on a reboot — and the
  files it mapped still cannot be overwritten, which fails the linker on `six-windows.exe` and `Copy-Item` on
  `BlocksRuntime.dll`. `six-windows.ps1` renames the old `.exe` aside (renaming a mapped image works where
  overwriting does not) and leaves a locked DLL alone, since it is already the file the copy would have written.
- **`pkill -x six` kills the Release browser** — Artem's real one, with his real state. It is named in the rule above
  and it is still the easy thing to type. Kill by path: `pkill -f "Debug/six.app/Contents/MacOS/six"`. That kill is
  by path and not by process, so it also takes down the **other session's** dev six, however they launched it —
  a run of `SIX_KEY_SELFTEST` every few minutes looks from over there like an unexplained SIGKILL at 75–135 s with no
  crash report. Say so before a series of them, and ask before taking the app down if someone needs a long window.

## How we work

- **Ask before reaching for a hand-written integration.** Search for an existing Swift library first and report what
  you found (stars, activity, licence) with a build-vs-buy recommendation.
- **No regressions on macOS or iOS/iPadOS.** This is a standing constraint from the Linux and Android work: anything
  touching Apple code has to be provably inert or explicitly justified.
- **Commit when asked ("закомить"), never push unless asked.** Work lands on `main` unless a branch was requested.
- **Two sessions cannot both drive synthetic input on one desktop.** A click has to be delivered to a foreground
  window, so two harnesses posting clicks steal the foreground from each other mid-test and land on the wrong
  windows entirely — the `../sixty` session could not verify its click test at all while this one was running, and
  once tripped Windows' task-view switcher by accident. Say so before a run, and prefer `PrintWindow` over a screen
  scrape for anything that only needs to *look*: it captures a window that is not on top, and does not touch focus.
- **A DPI-unaware measuring process makes a correct window look wrong, and it has now cost two sessions.** Windows
  lies to such a process at 96 DPI for *every* query it makes, diagnostics included, so a rect or a cursor position
  read there comes back divided by the display scale — and against a Per-Monitor-V2 app it reads exactly like
  "drawn at one size, hit-tested at another". The Windows front's top bar was reported as that bug and is not: it
  draws and hit-tests through one `chromeLayout()`, and the app's own `SIX_UI_DEBUG` line says `scale=1.5`. Call
  `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` first thing in the harness, and when
  a measurement disagrees with the app, suspect the harness before the app.
- **Other Claude sessions edit this repo at the same time.** Check `git status` before committing and stage only your
  own files; an unexpected diff is usually another session's work in progress (or Xcode re-sorting `project.pbxproj`),
  not something to revert. Ask the session rather than guessing — a source file under someone's hand looks exactly
  like debris. Two files are the **exception**, because nobody edits either deliberately and an unclaimed diff in
  them is always mechanical: `Package.resolved`, where it is a stray resolve (above), and the root `Info.plist`.
- **A `swift build` of the root package overwrites the root `Info.plist`.** `SixCore` is `path: "six"` and the String
  Catalogs there are resources, so SwiftPM builds a resource bundle — and stages it into the *package root*, dropping
  its generated 497-byte `BNDL` plist (`CFBundleIdentifier` `six-main.SixCore.resources`) on top of the real one and
  leaving copies of `InfoPlist.xcstrings` and `Localizable.xcstrings` beside it. The real file is what makes macOS
  treat six as a browser at all — the http/https claim, the document types, the camera and microphone prompt strings
  — so committing that diff ships a browser that cannot be made the default and whose permission prompts are blank.
  It sat dirty for two days once. `git checkout -- Info.plist` and delete the two stray catalogues; the tell is that
  they are byte-identical to the ones in `six/` and all three carry the same timestamp.
- **Commit messages are prose.** A sentence for the title — what changed, in the voice of the thing that changed
  ("The window that was closed comes back where it stood") — and a body that explains the why, the measurement, and
  what was left honest. No conventional-commits prefixes. Quotes in the subject break the shell; commit via
  `git commit -F -` with a heredoc.
- **A feature is not finished until the docs say so.** `docs/*.md` for whoever changes the code, and
  [`docs/guide/`](docs/guide/) — the VitePress user guide — **in both Russian and English**, naming buttons with the
  strings from `six/Localizable.xcstrings` rather than translating by eye. That build runs from `docs/guide` and
  writes into the sibling `xciii` site; VitePress drops the diacritic on «й» when slugifying anchors.
- **Localization**: everything a person reads goes through the String Catalogs, English and Russian. Everything a
  *model* reads — tool descriptions, the catalog's instructions, presets — stays English, because that is a prompt and
  not an interface. [docs/localization.md](docs/localization.md).
- **Comments explain why, not what**, and read like the surrounding code — the codebase's register is a short essay at
  the top of a type, and a line of reasoning where a decision looks arbitrary. Match it.
- Artem writes in Russian; the repo, the docs and the commit messages are in English.

## What is built, and what is not

Built: the rail and workspaces with the full gesture set, profiles with isolated data stores, persistence (a SQLite
system of record plus a versioned JSON snapshot), history and bookmarks with on-device multilingual embeddings and
personal search on the start page, ad/tracker blocking down to scriptlets and extended CSS, extra certificate
authorities, `WKWebExtension` hosting, site permissions, downloads, page translation, picture-in-picture, the ⌘K
assistant, the ACP agent panel, `six --mcp`, MCP apps (SEP-1865) with OAuth, deep research with document windows and
highlights, DevTools capture, localization, and the Linux, Android and Windows fronts at the parity levels their
docs state.

Not built, with reasons: [docs/todo.md](docs/todo.md) — web archives, bookmark images, the content-script boundary
`WebPage` cannot cross, geolocation and screen sharing, floating windows, passkeys, CloudKit sync, and what the
Linux front still owes the Mac.
