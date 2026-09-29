# Build

```sh
xcodebuild -project Savoia.xcodeproj -scheme Savoia -configuration Debug build
```

macOS 27 beta, Swift 5 language mode. Add `-skipMacroValidation` on the command line: the SQLiteData package
brings Swift macros (`@Table`, `#sql`), which Xcode wants trusted once in the UI and `xcodebuild` refuses otherwise.

```sh
xcodebuild -project Savoia.xcodeproj -scheme Savoia -configuration Debug -skipMacroValidation -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` is for build plugins: mlx-swift ships one (`CudaBuild`). mlx-swift
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

For the same reason `ClaudeForFoundationModels` and Apple's own `ChatCompletionsLanguageModel` (from
[foundation-models-utilities](https://github.com/apple/foundation-models-utilities)) are vendored into `Savoia/Vendor/`
and compiled into the app target: a SwiftPM dependency would ignore the `SDKROOT` override, and both touch the
Foundation Models executor ABI. Each vendored tree keeps a `VENDORED.md` saying where it came from and what was
changed; those notes are excluded from the app target, since two files of that name would otherwise land on the same
path in `Resources`.
Ordinary packages are fine — [SQLiteData](https://github.com/pointfreeco/sqlite-data) (GRDB, StructuredQueries and
the rest of its tree), [sqlite-vec-data](https://github.com/mhayes853/sqlite-vec-data),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (`MLXEmbedders`, with mlx-swift underneath),
[swift-huggingface](https://github.com/huggingface/swift-huggingface),
[swift-transformers](https://github.com/huggingface/swift-transformers) (`Tokenizers`) and
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) (`ContentBlockerConverter`, for
[content blocking](blocking.md)) are normal SwiftPM dependencies of the target and build under the override without
trouble. SafariConverterLib pins `swift-argument-parser` to exactly 1.5.0 for a command-line target Savoia does not
link, which pulls the resolved version down from 1.8.2; nothing in the tree needs the newer one. Its converter also
prints a line per unconvertible rule on stdout in **Debug** builds only (its own `#if DEBUG`), which is a few hundred
lines at first launch and silence in Release. mlx-swift-lm's `MLXHuggingFace` product is deliberately
*not* linked: it depends on `MLXFoundationModels`, a third-party `LanguageModel` over the executor ABI.


**The override is redundant with release Xcode 27.0 (27A266a), and still there.** Its macOS SDK and the Command
Line Tools one are the same build, 26A425, with identical `FoundationModels.framework` (checked 27 September 2026).
Removing `SDKROOT` and the plugin path, and moving `Savoia/Vendor` back to packages, is a decision still to be made, not
a fix.

## A DMG to install from

```sh
./scripts/dmg.sh
```

Builds the Release configuration into `dist/DerivedData` (kept out of the shared one so the artefacts are the ones
that go into the image), stages `Savoia.app` next to a symlink to `/Applications`, and writes `dist/savoia-<version>.dmg`.
The version is `MARKETING_VERSION` read out of the project. Mount it, drag Savoia across, done.

There is no signing identity on this machine (`security find-identity -v -p codesigning` finds none), so the app is
signed ad-hoc — the same "Sign to Run Locally" a Debug build gets. That is enough to install and run it *here*:
a DMG made locally carries no quarantine flag.

Giving the image to someone else is a different matter. Ad-hoc code has no team behind it, so Gatekeeper on their
machine refuses it outright — they would have to right-click › Open, or `xattr -dr com.apple.quarantine
/Applications/Savoia.app`. Doing it properly means a Developer ID Application certificate, `ENABLE_HARDENED_RUNTIME`
(with the entitlements the ACP layer needs to keep spawning `npx` — `com.apple.security.cs.allow-jit` and
`disable-library-validation` are the usual suspects), `codesign --options runtime --deep` and
`xcrun notarytool submit … --wait` followed by `xcrun stapler staple`. None of that is set up yet.

## Two apps: the one you use and the one you build

A **Debug** build is `org.deffun.savoia.dev`, shows up as **Savoia dev** under an icon of its own, and keeps everything
under `~/Library/Application Support/org.deffun.savoia.dev` — the database, the snapshot, bookmarks, thumbnails, the
MCP socket. A **Release** build is `org.deffun.savoia` under `…/org.deffun.savoia`, and that is the app that gets
installed. Nothing decides this: the folder *is* the identifier (`AppSupport`), so two identifiers are two folders
the way a sandboxed app gets two containers for free, and there is no rule to keep in step with the build settings.

So the browser you are using and the browser you are changing sit side by side, and killing, rebuilding and
relaunching one all afternoon does nothing to the other. They could not have shared: the snapshot is rewritten
whole, the SQLite file is opened for writing, and there is one socket at one path — two Savoias on one directory
means the second one finding the socket taken and the two of them overwriting each other's windows.

Site data separates itself, because WebKit files a non-sandboxed app's cookies and storage under
`~/Library/WebKit/<bundle identifier>`. That is the point of it and also the cost: a development Savoia starts logged
out of everything. To start it from a copy of the real one instead — with **both** Savoias quit, or the copy is of a
database mid-write:

```sh
cp -R ~/Library/Application\ Support/org.deffun.savoia ~/Library/Application\ Support/org.deffun.savoia.dev
cp -R ~/Library/WebKit/org.deffun.savoia ~/Library/WebKit/org.deffun.savoia.dev
```

A development build never offers to become the default browser: two apps with one face, and only one of them should
be catching every link on the machine.

## The icon

Made from [`docs/logo.png`](logo.png) by [`scripts/appicon.swift`](../scripts/appicon.swift):

```sh
swift scripts/appicon.swift docs/logo.png Savoia/Assets.xcassets/AppIcon.appiconset Savoia/Assets.xcassets/AppIcon-Dev.appiconset
```

The development build's set carries an orange DEV band, so the two can be told apart in the Dock.

## Sandbox

App Sandbox is off — the ACP layer spawns `npx` / `claude` / `codex` from the user's toolchain.

