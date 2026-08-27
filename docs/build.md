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
The first build with MLX takes several minutes (C++ and Metal); after that it is incremental.

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
[swift-huggingface](https://github.com/huggingface/swift-huggingface) and
[swift-transformers](https://github.com/huggingface/swift-transformers) (`Tokenizers`) are normal SwiftPM dependencies
of the target and build under the override without trouble. mlx-swift-lm's `MLXHuggingFace` product is deliberately
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

## Sandbox

App Sandbox is off — the ACP layer spawns `npx` / `claude` / `codex` from the user's toolchain.
