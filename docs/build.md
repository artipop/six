# Build

```sh
xcodebuild -project six.xcodeproj -scheme six -configuration Debug build
```

macOS 27 beta, Swift 5 language mode. Add `-skipMacroValidation` on the command line: the SQLiteData package
brings Swift macros (`@Table`, `#sql`), which Xcode wants trusted once in the UI and `xcodebuild` refuses otherwise.

```sh
xcodebuild -project six.xcodeproj -scheme six -configuration Debug -skipMacroValidation -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` is the same story for build plugins: mlx-swift ships one (`CudaBuild`). mlx-swift
also compiles Metal shaders, which needs the **Metal Toolchain** component — once,
`xcodebuild -downloadComponent MetalToolchain` (~840 MB); without it the build stops at `cannot execute tool 'metal'`.
The first build with MLX takes several minutes (C++ and Metal); after that it is incremental. Debug builds run MLX
at -O0 like every package dependency — embedding a page is 3–4× slower than in Release ([bookmarks.md](bookmarks.md#embeddings)).

Files are added to the target automatically (the project uses a synchronized
file group), so new sources need no project edits.

## SDK override

The target sets `SDKROOT` to the macOS 27 SDK from the **Command Line Tools** beta
(`/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`, build 26A5406c, FoundationModels 2.0.68 — the revision the
OS runtime ships) plus a `-plugin-path` for `SwiftUIMacros`. The installed Xcode carries an older SDK whose Foundation
Models *executor* ABI doesn't match the OS and crashes third-party `LanguageModel`s on launch. Drop both settings once
Xcode's own SDK matches the OS.

For the same reason `ClaudeForFoundationModels` is vendored into `six/Vendor/` and compiled into the app target: a
SwiftPM dependency would ignore the `SDKROOT` override, and that library touches the Foundation Models executor ABI.
Ordinary packages are fine — [SQLiteData](https://github.com/pointfreeco/sqlite-data) (GRDB, StructuredQueries and
the rest of its tree), [sqlite-vec-data](https://github.com/mhayes853/sqlite-vec-data),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (`MLXEmbedders`, with mlx-swift underneath),
[swift-huggingface](https://github.com/huggingface/swift-huggingface),
[swift-transformers](https://github.com/huggingface/swift-transformers) (`Tokenizers`) and
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) (`ContentBlockerConverter`, for
[content blocking](blocking.md)) are normal SwiftPM dependencies of the target and build under the override without
trouble. SafariConverterLib pins `swift-argument-parser` to exactly 1.5.0 for a command-line target six does not
link, which pulls the resolved version down from 1.8.2; nothing in the tree needs the newer one. Its converter also
prints a line per unconvertible rule on stdout in **Debug** builds only (its own `#if DEBUG`), which is a few hundred
lines at first launch and silence in Release. mlx-swift-lm's `MLXHuggingFace` product is deliberately
*not* linked: it depends on `MLXFoundationModels`, a third-party `LanguageModel` over the executor ABI.

## A DMG to install from

```sh
./scripts/dmg.sh
```

Builds the Release configuration into `dist/DerivedData` (kept out of the shared one so the artefacts are the ones
that go into the image), stages `six.app` next to a symlink to `/Applications`, and writes `dist/six-<version>.dmg`.
The version is `MARKETING_VERSION` read out of the project. Mount it, drag six across, done.

There is no signing identity on this machine (`security find-identity -v -p codesigning` finds none), so the app is
signed ad-hoc — the same "Sign to Run Locally" a Debug build gets. That is enough to install and run it *here*:
a DMG made locally carries no quarantine flag.

Giving the image to someone else is a different matter. Ad-hoc code has no team behind it, so Gatekeeper on their
machine refuses it outright — they would have to right-click › Open, or `xattr -dr com.apple.quarantine
/Applications/six.app`. Doing it properly means a Developer ID Application certificate, `ENABLE_HARDENED_RUNTIME`
(with the entitlements the ACP layer needs to keep spawning `npx` — `com.apple.security.cs.allow-jit` and
`disable-library-validation` are the usual suspects), `codesign --options runtime --deep` and
`xcrun notarytool submit … --wait` followed by `xcrun stapler staple`. None of that is set up yet.

## Two apps: the one you use and the one you build

A **Debug** build is `org.deffun.six.dev`, shows up as **six dev** under an icon of its own, and keeps everything
under `~/Library/Application Support/org.deffun.six.dev` — the database, the snapshot, bookmarks, thumbnails, the
MCP socket. A **Release** build is `org.deffun.six` under `…/org.deffun.six`, and that is the app that gets
installed. Nothing decides this: the folder *is* the identifier (`AppSupport`), so two identifiers are two folders
the way a sandboxed app gets two containers for free, and there is no rule to keep in step with the build settings.

So the browser you are using and the browser you are changing sit side by side, and killing, rebuilding and
relaunching one all afternoon does nothing to the other. They could not have shared: the snapshot is rewritten
whole, the SQLite file is opened for writing, and there is one socket at one path — two sixes on one directory
means the second one finding the socket taken and the two of them overwriting each other's windows.

Site data separates itself, because WebKit files a non-sandboxed app's cookies and storage under
`~/Library/WebKit/<bundle identifier>`. That is the point of it and also the cost: a development six starts logged
out of everything. To start it from a copy of the real one instead — with **both** sixes quit, or the copy is of a
database mid-write:

```sh
cp -R ~/Library/Application\ Support/org.deffun.six ~/Library/Application\ Support/org.deffun.six.dev
cp -R ~/Library/WebKit/org.deffun.six ~/Library/WebKit/org.deffun.six.dev
```

A development build never offers to become the default browser: two apps with one face, and only one of them should
be catching every link on the machine.

## The icon

Drawn rather than painted, by [`scripts/appicon.swift`](../scripts/appicon.swift):

```sh
swift scripts/appicon.swift six/Assets.xcassets/AppIcon.appiconset six/Assets.xcassets/AppIcon-Dev.appiconset
```

It is the strip — three columns side by side, the focused one tall and bright in the middle, its neighbours dimmer
and cut off by the icon's own edge, because a strip does not stop at the screen and that is the one thing no other
browser's icon says. Detail goes as the icon shrinks (the title bar below 256 px, the word DEV below 64) and the
silhouette stays: three bars, the middle one taller.

The second set is the same icon under an amber ribbon, the way every browser marks its nightly, and the macOS Debug
configuration is the only thing pointing at it (`ASSETCATALOG_COMPILER_APPICON_NAME`). Ten sizes for the Mac from
16 to 512@2x, plus one 1024 for the phone, which takes a single size and masks it itself. Each is drawn straight
into a bitmap of the exact pixel size — an `NSImage` with `lockFocus` renders at the screen's backing scale and
comes out twice as big on a Retina Mac, which actool rejects.

## Sandbox

App Sandbox is off — the ACP layer spawns `npx` / `claude` / `codex` from the user's toolchain.
