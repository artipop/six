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

Built on the macOS 26/27 APIs on purpose: SwiftUI `WebView`/`WebPage` (no `NSViewRepresentable`), Foundation Models as
the single LLM API, ACP for agents, and the browser itself as an MCP server. Swift 5 language mode, `@Observable`,
`@MainActor`.

## Where things are

```
six/Niri          NiriLayout (workspaces, columns, geometry, focus/move), NiriScrollMonitor (⌥+scroll gestures)
six/Browser       BrowserState, BrowserTab (WebPage), Profile/ProfileStore, History, SearchEngine, LivePageCache,
                  SitePermissions, CertificateStore, Downloads, IDN, PersonalSuggestions, PageThumbnails
six/Views         ContentView (top bar), NiriStripView (rail + overview), StartPage, SettingsPageView, AssistantBar,
                  AgentPanel, MCPApps*, Phone/ (the iOS layout)
six/Data          AppSupport (the one place that knows the bundle id → folder), AppDatabase, SettingsStore
six/Persistence   AppStateSnapshot, SnapshotStore (versioned JSON), StatePersistence (debounced autosave)
six/Bookmarks     Bookmark(Store), ReadablePage (Markdown copy), Embedder/MLXEmbedder (on-device, multilingual-e5)
six/Blocking      ContentBlocker (WKContentRuleList per profile), FilterList(Store), RuleConversion
six/Extensions    ExtensionStore (a controller per profile), ExtensionInstaller + the compatibility verdict
six/Translation   the portable half (segments, batching, the page script) + AppleTranslator behind it
six/ACP           JSONRPCConnection, ACPClient (actor), ACPAgent (process), AgentSessionStore (view model)
six/MCP           MCPServer + MCPSocket + MCPStdioBridge (`six --mcp`), Client/ (MCP apps, SEP-1865, OAuth, catalog)
six/Tools         BrowserTools — one catalog, served to the assistant, to ACP agents and over MCP
six/Vendor        ClaudeForFoundationModels, FoundationModelsUtilities — compiled into the target, see below
```

`SixCore` (root `Package.swift`) is the slice that must build on **Linux**: `NiriLayout`, the storage layer, the
profile/bookmark/permission/translation models, and the wire half of ACP/MCP. A file joins it by being listed in
`sources:` — see the essay at the top of that manifest before editing it.

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
```

Details, and the SDK override, in [docs/build.md](docs/build.md).

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

## Things that have cost hours

- **The SDK override is load-bearing.** The target sets `SDKROOT` to the *Command Line Tools* macOS 27 SDK because
  Xcode's own SDK has an older Foundation Models executor ABI than the OS and crashes third-party `LanguageModel`s on
  launch. That is also why `six/Vendor/` exists: a SwiftPM target would ignore the override. Don't move those back to
  packages until Xcode's SDK matches.
- **`Package.resolved` is frozen on purpose**, seeded from the app's own graph. `swift package update` is a
  Linux-breaking command here (see [UPSTREAM.md](UPSTREAM.md)), and a plain `swift build`/`swift test` rewrites the
  file. If one slipped through: `git checkout -- Package.resolved`.
- **Linux build plans are cached.** Editing the root `Package.swift` does not invalidate llbuild's description —
  `swift build` says "Build complete!" in 0.1 s and never compiles the added file. `rm -f <scratch>/build.db` first.
  To prove `SixCore` still builds on Linux without the whole GTK front: the plain `swift:6.3.3-noble` image needs
  `libsqlite3-dev` and `--memory 4g`, or it stalls silently around 120/453.
- **WebKitGTK cannot be brewed on macOS** (`depends_on :linux`, and brew's build is GTK3/4.1 anyway). The Linux front
  stays in the container. [docs/linux.md](docs/linux.md) has the full checked list.
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

## How we work

- **Ask before reaching for a hand-written integration.** Search for an existing Swift library first and report what
  you found (stars, activity, licence) with a build-vs-buy recommendation.
- **No regressions on macOS or iOS/iPadOS.** This is a standing constraint from the Linux and Android work: anything
  touching Apple code has to be provably inert or explicitly justified.
- **Commit when asked ("закомить"), never push unless asked.** Work lands on `main` unless a branch was requested.
- **Other Claude sessions edit this repo at the same time.** Check `git status` before committing and stage only your
  own files; an unexpected diff is usually another session's work in progress (or Xcode re-sorting `project.pbxproj`),
  not something to revert.
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
personal search on the start page, ad/tracker blocking, extra certificate authorities, `WKWebExtension` hosting, site
permissions, downloads, page translation, the ⌘K assistant, the ACP agent panel, `six --mcp`, MCP apps (SEP-1865) with
OAuth, deep research with document windows and highlights, DevTools capture, localization, and the Linux and Android
fronts at the parity levels their docs state.

Not built, with reasons: [docs/todo.md](docs/todo.md) — web archives, bookmark images, the content-script boundary
`WebPage` cannot cross, geolocation and screen sharing, picture-in-picture, passkeys, CloudKit sync, and what the
Linux front still owes the Mac.
