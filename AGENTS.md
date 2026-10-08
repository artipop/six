# AGENTS.md

Working notes for whoever changes this code. [README.md](README.md) is the pitch, [docs/](docs/) is the reference;
this file is the part that is neither — how to build it, how to check it, and the things that have cost hours.

## What Savoia is

A macOS browser with tabs, tab groups and two tabs side by side, built on the macOS 26/27 APIs on purpose: SwiftUI
for the interface, a `WKWebView` per tab that Savoia creates itself, Foundation Models as the single LLM API, ACP
for agents, and the browser itself as an MCP server. A tab was SwiftUI's `WebView`/`WebPage` until October 2026;
what the move changed is in [docs/architecture.md](docs/architecture.md#from-webpage-to-wkwebview). Swift 5 language mode, `@Observable`, `@MainActor`.

It was called **six** until September 2026: bundle ids, folders and the `six://` scheme were renamed with it,
and `FormerName` carries the old Application Support, WebKit data, preferences and Keychain items across.

**The `dev` branch** keeps what `main` dropped: the scrollable-tiling row (windows on a horizontal row, workspaces
stacked vertically, the overview and the `⌥` keys) and the iOS, Linux, Windows and Android fronts, which were all
built on the row. It is synced from `main` now and then, and may be dropped. The model underneath is the same on both
branches — `TilingLayout`, workspaces and columns — which is why the names in `main` still say so: a workspace is a
tab group, a column is one tab or two side by side.

## Where things are

```
Savoia/Tiling        TilingLayout — workspaces (tab groups) and columns (a tab, or two side by side), focus and moves
Savoia/Tabs          TabSorter, TabTopics (groups by meaning), GroupColor, the local language model
Savoia/Input         KeyBindings + KeyContext (the table, in SavoiaCore), KeyEvents (the AppKit half), KeyRouter, KeySelfTest
Savoia/Browser       BrowserState, BrowserTab (its own WKWebView) + PageDelegate, Profile/ProfileStore, History, SearchEngine, LivePageCache,
                     SitePermissions, Geolocation + SiteNotifications (the providers WebKit asks, C SPI), CertificateStore, Downloads, IDN, PersonalSuggestions, PageThumbnails, PageFinder,
                     WindowSwitcher (the ⌃Tab ring)
Savoia/Views         ContentView, TabStripView (tab bar + toolbar), TabPageView (one tab's page), PageHost, StartPage,
                     ConfigurationPageView, AssistantBar, AgentPanel, MCPApps*
Savoia/Data          AppSupport (the one place that knows the bundle id → folder), AppDatabase, ConfigurationStore,
                     FormerName (moves the state of the browser once called six, on the first launch)
Savoia/Persistence   AppStateSnapshot, SnapshotStore (versioned JSON), StatePersistence (debounced autosave)
Savoia/Bookmarks     Bookmark(Store), ReadablePage (Markdown copy), Embedder/MLXEmbedder (on-device, multilingual-e5),
                     TextChunker + VectorIndex + BookmarkIndexer, Embedding/ — E5 as transformers.js in a PageSandbox
Savoia/Blocking      ContentBlocker (WKContentRuleList per profile), FilterList(Store), RuleConversion,
                     AdvancedRules (scriptlets + extended CSS, in the page), Payload/ (built JS)
Savoia/Extensions    ExtensionStore (a controller per profile), ExtensionInstaller + the compatibility verdict
Savoia/Translation   segments, batching, the page script, LanguageGuess, AppleTranslator; Bergamot/ — Marian as wasm
Savoia/ACP           JSONRPCConnection, ACPClient (actor), ACPAgent (process), AgentSessionStore (view model)
Savoia/MCP           MCPServer + MCPSocket + MCPStdioBridge (`Savoia --mcp`), Client/ (MCP apps, SEP-1865, OAuth, catalog)
Savoia/Speech        dictation: MicrophoneCapture, ParakeetTranscriber (FluidAudio), DictationStore, the button
Savoia/DevTools      DevToolsStore (console and network capture), WebInspector (⌥⌘I, SPI), Automation (remote automation)
Savoia/Tools         BrowserTools — one catalog, served to the assistant, to ACP agents and over MCP
Savoia/WebMCP        pages declaring tools for agents: polyfill, registry, calls, WebMCPStore — docs/webmcp.md
```

`SavoiaCore` (root `Package.swift`) is the slice the tests run against: `TilingLayout`, the storage layer, the
profile/bookmark/permission/translation models, the key bindings, and the wire half of ACP/MCP. A file joins it by
being listed in `sources:`.

New files under `Savoia/` need no project edits (`PBXFileSystemSynchronizedRootGroup`).

## Build

```sh
# macOS — both skip flags are required (SQLiteData macros, mlx-swift's CudaBuild plugin)
xcodebuild -project Savoia.xcodeproj -scheme Savoia -configuration Debug \
  -skipMacroValidation -skipPackagePluginValidation build

# SavoiaCore and its tests — ALWAYS with the flag, on every invocation
swift build --disable-automatic-resolution
swift test  --disable-automatic-resolution

./scripts/dmg.sh          # Release → dist/savoia-<version>.dmg
./scripts/profile.sh      # Instruments trace, all processes, while the Release Savoia runs → dist/profiles

# Vendored JavaScript. Both write committed output, so a normal build needs neither network nor
# Node; run one only when the upstream version it pins moves.
./scripts/blocking-payload.sh     # AdGuard's scriptlets and extended CSS → Savoia/Blocking/Payload
./scripts/bergamot-payload.sh     # Emscripten's glue for bergamot-translator → Savoia/Translation/Payload
```

Details, and the SDK override, in [docs/build.md](docs/build.md).

## Running and checking a change

The fresh app is in DerivedData, **not** in the repo's `build/`:

```sh
ls -td ~/Library/Developer/Xcode/DerivedData/Savoia-*/Build/Products/Debug/Savoia.app | head -1
```

- Debug is `org.deffun.savoia.dev` ("Savoia dev"), Release is `org.deffun.savoia`. **They coexist and are meant to** — the
  Release one is Artem's real browser with real state. Never kill it; restart only the dev one, by its own id.
- `pkill -f "Debug/Savoia.app/Contents/MacOS/Savoia"` + `open -na <full path>`. Never `open -b <bundleid>`: with several copies registered, LaunchServices
  picks whichever it likes and two Savoias on one Application Support directory trap in WebKit.
- Launch from a non-sandboxed shell (`dangerouslyDisableSandbox`), or the app never initialises. A crash in
  `SavoiaApp.init` leaves no window and no stderr — run the binary directly once, or read `~/Library/Logs/DiagnosticReports/Savoia-*.ips`.
- **Savoia keeps a log now, and it does not need a terminal**: `~/Library/Logs/org.deffun.savoia.dev/savoia.log` for the dev
  build, plus the unified log (`/usr/bin/log show --last 1h --info --debug --predicate 'subsystem ==
  "org.deffun.savoia.dev"'` — `log` alone is a zsh builtin and dies with "too many arguments"). Everything that used to
  be an unread `[Savoia] …` on stderr is in both. [docs/logging.md](docs/logging.md).
- Before believing "it's still not there", check `ps -eo pid,lstart,command | grep MacOS/Savoia` — the process
  being looked at is often a stale Release build.

**Screenshots do not work here.** `screencapture` writes black (no Screen Recording for the terminal) and System Events
is refused (no Accessibility), so synthetic clicks, hover and menu states cannot be captured. Savoia can draw its own
window, though: under `SAVOIA_TESTDRIVER=1`, `testdriver_window_image` writes the tab bar, the address field and the
page to a PNG — not menus, popovers or sheets, which are other windows. Verify through Savoia's own
MCP server — that is what it is for:

```sh
<Savoia.app>/Contents/MacOS/Savoia --mcp     # JSON-RPC on stdio, relays to the running app over its Unix socket
```

`open_window` with a `savoia://` address, `list_workspaces`, `get_page_content`, `evaluate_javascript`,
`list_console_messages`, `take_screenshot` (only for windows with a web page). See [docs/mcp.md](docs/mcp.md).

**Keys can be pressed, though — `NSApp.postEvent` needs no Accessibility.** It is the app's own queue, and a local
`NSEvent` monitor is exactly what pulls events out of it, so a synthetic `⌃Tab` goes through the real router and
opens the real ring. `SAVOIA_KEY_SELFTEST=1` does both halves: it prints what every binding answers in every context,
then posts the ring's keys and says where it landed (`Savoia/Input/KeySelfTest.swift`). `SAVOIA_TABS_SELFTEST=1`
runs the tab bar's verbs — groups, folding, picking, side by side — against the real browser. It does the
`⌘` keys too, which are menu items and not table rows: `menuKeys` makes the focused `WKWebView` first responder by
hand and then posts `⌘[` `⌘]` `⌘R`, because the interesting case is the one where WebKit is in front of the menu bar.
Add to it rather than reasoning about the keyboard from the source — the bug it was written to find had survived a
whole session of reasoning. Two things that make its output readable: a **control** key whose effect is not in doubt,
so "the item did nothing" can be told from "the key never arrived"; and that control going **last**, because `⌘T`
takes the selection with it and every key after it is then aimed at a fresh window with no history — which reads
exactly like WebKit swallowing the key, and was believed once. `SAVOIA_UI_DEBUG=1` prints a line per key press with the context it landed in and who took it.
**But `postEvent` goes past the system**, straight into the app's own queue — so a key the WindowServer
owns tests green and does nothing in the hand. `⌃←` / `⌃→` are Mission Control's *Move left/right a
space* (symbolic hotkeys 79 and 80, on by default) and never reach any application; the ring's
arrows are written `⌃⇧←` / `⌃⇧→` for that reason. When a key is reported dead and the table says it is
bound, read `defaults read com.apple.symbolichotkeys` before reading the router — and note that
`SAVOIA_UI_DEBUG` printing *nothing* is the tell, since a key that arrives and is declined still prints.

## Dependencies

There are two resolved graphs: the app's (`Savoia.xcodeproj/…/swiftpm/Package.resolved`, which leads — move versions
in Xcode first) and the root `Package.resolved` for `SavoiaCore`'s tests. They must agree on **GRDB, sqlite-data and
swift-structured-queries**, because a database written by one build is opened by the other; they sit at GRDB 7.11.1 /
sqlite-data 1.11.0 / structured-queries 0.37.0. A free resolve does not land there by itself (sqlite-data 1.11.0 does
not compile against structured-queries 0.38), so a version move is walked back with
`swift package resolve <package> --version` and read back before it is committed. [UPSTREAM.md](UPSTREAM.md) has the
regressions behind the pins.

Pass `--disable-automatic-resolution` to every `swift build` / `swift test`: a plain one resolves first and can
rewrite the root file. `xcodebuild` never touches it — the project holds only remote package references.

## Things that have cost hours

- **The project builds with the active Xcode's own SDK** (`SDKROOT = macosx`, Xcode 27.2 beta now). It used to pin the
  *Command Line Tools* `MacOSX27.0.sdk`; that pin fails with any Xcode lacking a
  `macosx27.0` SDK (`SDK lookup failed for canonical name`). `xcode-select -p` must point at an Xcode, not the Command
  Line Tools, or use `DEVELOPER_DIR`. [docs/build.md](docs/build.md#sdk).
- **The app target compiles main-actor-by-default** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so anything that
  does not say `nonisolated` is on the main actor — and the compiler complains at the *reader*, not at the
  declaration: a `static let` holding a path becomes a warning inside the detached save three files away. Say
  `nonisolated` as the code is written, on what is read off the main actor — pure value work (paths, hashing, wire
  decoding, an extension on `Data` or `Color`), and the constants a background closure reads. And a
  non-Sendable value cannot cross an isolation line at all: `MainActor.assumeIsolated` handing back an `NSEvent` is a
  warning, handing back the verdict about it is not. Keep the build warning-free: a build that prints dozens of
  warnings is one nobody reads.
- **A share extension is registered by bundle id, and another session's build answers for yours.** The
  copy in the *other* worktree's DerivedData carries the same `org.deffun.savoia.dev.share`, and
  LaunchServices picks one of them — so a rebuild here can change nothing that actually runs, and the
  new log lines simply never appear. `pluginkit -m -v -i <id>` prints the path that won; `pluginkit -r
  <the other .appex>` then `pluginkit -a <yours>` moves it, and `lsregister -f -R` on the app does not.
  A freshly built extension is also registered **disabled** — the leading `+` in that listing is the
  switch, and `pluginkit -e use -i <id>` is what System Settings' own toggle does.
- **A share extension's view must be a hosting *controller*, not an `NSHostingView`.** The sheet is a
  remote view owned by the app that shared, SwiftUI's sizing goes through the controller, and with a
  bare hosting view the remote view never gets a size and never appears: the host app dims and draws
  nothing, and Esc is the only way out. `viewDidAppear` never firing is the tell — an empty sheet still
  appears. [docs/sharing.md](docs/sharing.md).
- **A navigation the delegate cancels reports nothing afterwards** — no failure, no finish. A link that became a
  download or a tab left `loadSettled` waiting out its whole ceiling until the delegate told the tab
  (`BrowserTab.navigationCancelled`). Anything that waits on a navigation has to hear about the ones that were refused.
- **A web view's configuration is fixed when the view is made, and three things depend on which one it was.** A
  window a page opens keeps its opener only on the configuration `createWebView` hands over; an extension's own
  page loads only on `WKWebExtensionContext.webViewConfiguration` (-1008 otherwise); and a tab restored in front
  is built before its extension has loaded. Going from one kind to another is another view
  (`BrowserTab.materialize`, `extensionLoaded`). [docs/extensions.md](docs/extensions.md#extension-pages-are-tabs).
- **sqlite-vec on Apple's SQLite** works only per connection (`sqlite3_vec_init` from GRDB's `prepareDatabase`);
  `sqlite3_auto_extension` returns MISUSE. The e5 embedder needs `Pooling(strategy: .mean)` set explicitly.
- **A dynamic `import()` from a `file:` page is refused by WebKit; a static one is not.** ONNX Runtime loads its own
  glue that way, so an embedder page that reads its weights happily still answers "no available backend found. ERR:
  [wasm] TypeError: Importing a module script failed". Fetch the module as text and hand it back as a `blob:` URL
  (`EmbedderDriver`), and name the `.wasm` beside it, because the glue would otherwise resolve it against its own
  `import.meta.url`.
- **Sizes are fractions of the viewport, not point constants.** Artem is on a 5K display; a constant tuned on a laptop
  becomes a hairline there. Absolute numbers are fine only as floors/ceilings and for control metrics.
- **The dev Mac has 8 GB** and usually sits in macOS's `.warning` memory-pressure band already. Anything sized per GB
  lands at the bottom of its range; `.warning` paths are the normal case, not the edge case.
- **Never delete a credential or hard-to-recreate state file** to reproduce a first-run path. Copy it aside, or point
  the program at a throwaway config root.
- **`event.modifierFlags` carries more than the hand does.** macOS puts `.function` **and** `.numericPad` on every
  arrow key, and `.capsLock` on everything while Caps Lock is down; `deviceIndependentFlagsMask` keeps all three, so
  `flags == .option` is false for `⌥→`. Compare `KeyModifiers` (⌘⌃⌥⇧) and nothing else.
- **A `.disabled` on a SwiftUI `Commands` item is decided once, and a disabled item eats its key
  equivalent.** The body is not rebuilt when the model state it read changes, so `Back` greyed out on
  `canGoBack` stayed greyed out after a navigation and `⌘[` did nothing at all — measured with a run
  each way. Read the window *inside* the action and let the key be a no-op where it has nothing to
  do; `.disabled` on a `@FocusedValue` is the one form that does get rebuilt.
- **The system's Close item takes ⌘W back whenever SwiftUI fills the File menu in.** Savoia's own ⌘W item and AppKit's
  `performClose:` sat side by side, and a menu read straight after launch showed ours holding the key — but SwiftUI
  fills its menus in lazily (on opening, and when Savoia comes to the front), and after that the key was the system's:
  ⌘W a moment after switching to Savoia closed the one window, and Savoia quit after it. The log said
  `performKeyEquivalent:` → `performClick:` → `terminate:` with no tab closed. `CommandGroup(replacing: .saveItem) {}`
  removes Close and Close All. A menu dump that means anything calls `menuNeedsUpdate` on every submenu first
  (`TabsSelfTest.menuForCommandW`); without it you are reading what the menu held last time.
- **A letter binding read from `charactersIgnoringModifiers` is a binding that only Latin layouts have.** `⌥⇧P` reports
  «з» on the Russian layout. Match the key code as well (`KeyBinding.Key.letter`).
- **`pkill -x Savoia` kills the Release browser** — Artem's real one, with his real state, and it is the easy thing to
  type. Kill by path: `pkill -f "Debug/Savoia.app/Contents/MacOS/Savoia"`. That kill is
  by path and not by process, so it also takes down the **other session's** dev Savoia, however they launched it —
  a run of `SAVOIA_KEY_SELFTEST` every few minutes looks from over there like an unexplained SIGKILL at 75–135 s with no
  crash report. Say so before a series of them, and ask before taking the app down if someone needs a long window.
- **A page API that wants a person is refused over `Savoia --mcp`, fast and without a word.**
  `Notification.requestPermission()` needs a user gesture and answers `denied` in milliseconds without one;
  `getDisplayMedia()` needs the page to have focus and throws `InvalidStateError` while Savoia is not the front app.
  Neither refusal reaches Savoia's own code, so a `denied` from `evaluate_javascript` says nothing about the permission
  code under test. Send a real click — `testdriver_click` under `SAVOIA_TESTDRIVER`, or the agent's `click` — or have
  Artem click ([docs/permissions.md](docs/permissions.md#notifications)).

- **`WKWebView.callAsyncJavaScript` is a user gesture to WebKit.** After it the page has `userActivation.isActive` and may
  read the clipboard or open a window; a test stand that polled pages with it had every page activated for a whole
  run, and results that came and went. `BrowserTab.callWithoutGesture` is the call that is not
  ([docs/page-scripts.md](docs/page-scripts.md)).
- **A page nobody can see behaves differently, and a sleeping display hides all of them.** `visibilityState` is
  `hidden`, `requestFullscreen()` is refused with a `TypeError`. A long unattended run crosses the display-sleep
  timer; `scripts/permissions-wpt.py` holds the display awake with `caffeinate -d`.
- **`*.localhost` is not a neutral test host.** Plain http there is a secure context, and each host is a site of
  its own to WebKit, so "non-secure" and "same-site" tests measure nothing. wpt's own names in `/etc/hosts` are the
  ones Safari is run on ([docs/test-suites.md](docs/test-suites.md)).

## How we work

- **Ask before reaching for a hand-written integration.** Search for an existing Swift library first and report what
  you found (stars, activity, licence) with a build-vs-buy recommendation.
- **No regressions on macOS.** Anything
  touching Apple code has to be provably inert or explicitly justified.
- **Commit when asked ("закомить"), never push unless asked.** Work lands on `main` unless a branch was requested.
- **Other Claude sessions edit this repo at the same time.** Check `git status` before committing and stage only your
  own files; an unexpected diff is usually another session's work in progress (or Xcode re-sorting `project.pbxproj`),
  not something to revert. Ask the session rather than guessing — a source file under someone's hand looks exactly
  like debris. Two files are the **exception**, because nobody edits either deliberately and an unclaimed diff in
  them is always mechanical: `Package.resolved`, where it is a stray resolve (above), and the root `Info.plist`.
- **A `swift build` of the root package overwrites the root `Info.plist`.** `SavoiaCore` is `path: "Savoia"` and the String
  Catalogs there are resources, so SwiftPM builds a resource bundle — and stages it into the *package root*, dropping
  its generated 497-byte `BNDL` plist on top of the real one and leaving copies of `InfoPlist.xcstrings` and
  `Localizable.xcstrings` beside it. Its `CFBundleIdentifier` is `<checkout folder>.SavoiaCore.resources`: SwiftPM takes
  a root package's identity from the directory rather than from the `name:` in the manifest, so the prefix follows
  whatever the clone happens to be called. The real file is what
  makes macOS treat Savoia as a browser at all — the http/https claim, the document types, the camera and microphone
  prompt strings — so committing that diff ships a browser that cannot be made the default and whose permission
  prompts are blank. `git checkout -- Info.plist` and delete the two stray
  catalogues; the tell is that they are byte-identical to the ones in `Savoia/` and all three carry the same timestamp.
- **Commit messages are prose.** A sentence for the title — what changed, in the voice of the thing that changed
  ("The window that was closed comes back where it stood") — and a body that explains the why, the measurement, and
  what was left honest. No conventional-commits prefixes. Quotes in the subject break the shell; commit via
  `git commit -F -` with a heredoc.
- **`docs/todo.md` is an index and nothing is written in it.** What is found and not done gets a document of its
  own — a task in `docs/tasks/`, written to be handed to a fresh session, or a section of the `docs/*.md` it belongs
  to — and todo.md gets at most the one row that points there. The same for what is not built and why: the reason
  lives beside the thing, not in the list.
- **A feature is not finished until the docs say so.** `docs/*.md` for whoever changes the code, and
  [`docs/guide/`](docs/guide/) — the VitePress user guide — **in both Russian and English**, naming buttons with the
  strings from `Savoia/Localizable.xcstrings` rather than translating by eye. That build runs from `docs/guide` and
  writes `docs/guide/.vitepress/dist`; the sibling `deffun` project composes the published site
  (`ONLY=savoia npm run build` there). VitePress drops the diacritic on «й» when slugifying anchors.
- **Localization**: everything a person reads goes through the String Catalogs, English and Russian. Everything a
  *model* reads — tool descriptions, the catalog's instructions, presets — stays English, because that is a prompt and
  not an interface. [docs/localization.md](docs/localization.md).
- **The interface never narrates what Savoia does.** No "Savoia writes what it did to …", no "Savoia trusts what this Mac
  trusts", no "Savoia reads PEM and DER" — a label names the thing, a caption names a consequence or a missing step, and
  neither is a place for the program to describe itself in the third person. Name the value and let the row's label
  say what it is ("File", then the path), rather than wrapping it in a sentence about the browser. Savoia as the *object*
  of a verb the person performs is fine and stays — "Show Savoia in the Share Menu", "Set Savoia as Default Browser…".
- **Comments are few and one line long.** Only where a decision would look wrong without one, and never an essay on a
  type — older code still has those, and it is not the register to match. No measurements, model outputs, quoted
  strings from a test, or the story of the bug a fix came from: those go in the commit message and `docs/*.md`.
  Self-explanatory code gets no comment at all.
- Artem writes in Russian; the repo, the docs and the commit messages are in English.

## What is built, and what is not

Built: tabs with groups, folding, pinning, picking and two tabs side by side, groups by meaning, the ⌃Tab ring,
profiles with isolated data stores, persistence (a SQLite system of record plus a versioned JSON snapshot), history and
bookmarks with on-device multilingual embeddings and personal search on the start page, ad/tracker blocking (its
page half, scriptlets and extended CSS, switched off for now), extra certificate authorities, `WKWebExtension` hosting, site permissions, geolocation, site notifications, downloads,
page translation, find on page (⌘F), windows a page opens as tabs that keep their opener, extension pages as tabs, Save As with web archives, picture-in-picture, the ⌘E assistant, ACP agents and chats, `Savoia --mcp`, MCP
apps (SEP-1865) with OAuth, deep research with document tabs and highlights, DevTools capture, remote automation, dictation, localization.

Not built, with reasons: [docs/todo.md](docs/todo.md) — bookmark images, Apple Pay, floating windows, passkeys, CloudKit sync.
What is specified and waiting for a session: [docs/tasks/](docs/tasks/README.md). What Savoia is waiting on Apple to make public, and how to notice when it does:
[docs/api-watch.md](docs/api-watch.md).
