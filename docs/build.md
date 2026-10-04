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

## SDK

The project builds with the active Xcode's own macOS SDK (`SDKROOT = macosx`), currently Xcode 27.2 beta (27B5028f,
`MacOSX27.2.sdk`) with `MACOSX_DEPLOYMENT_TARGET = 27.0`. Until September 2026 the project pinned `SDKROOT` to the
Command Line Tools' `MacOSX27.0.sdk` plus a `-plugin-path` for `SwiftUIMacros`, because an earlier Xcode SDK carried a
Foundation Models *executor* ABI that did not match the OS and crashed third-party `LanguageModel`s on launch. That pin
broke with any Xcode that has no `macosx27.0` SDK of its own: the share extension's Info.plist step looks the SDK up by
canonical name and stops at `SDK lookup failed for canonical name: macosx27.0`.

The remote models are ordinary packages: [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels)
(`upToNextMinor` from 0.2.2) and Apple's
[foundation-models-utilities](https://github.com/apple/foundation-models-utilities) for `ChatCompletionsLanguageModel`
(exactly `1.1.0-beta1` — a prerelease, which a range would not pick up). Under the pin both were copied into
`Savoia/Vendor/` and compiled into the app target, because a package target ignored the override.
Ordinary packages are fine — [SQLiteData](https://github.com/pointfreeco/sqlite-data) (GRDB, StructuredQueries and
the rest of its tree), [sqlite-vec-data](https://github.com/mhayes853/sqlite-vec-data),
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (`MLXEmbedders`, with mlx-swift underneath),
[swift-huggingface](https://github.com/huggingface/swift-huggingface),
[swift-transformers](https://github.com/huggingface/swift-transformers) (`Tokenizers`) and
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) (`ContentBlockerConverter`, for
[content blocking](blocking.md)) are normal SwiftPM dependencies of the target and build without trouble. SafariConverterLib pins `swift-argument-parser` to exactly 1.5.0 for a command-line target Savoia does not
link, which pulls the resolved version down from 1.8.2; nothing in the tree needs the newer one. Its converter also
prints a line per unconvertible rule on stdout in **Debug** builds only (its own `#if DEBUG`), which is a few hundred
lines at first launch and silence in Release. mlx-swift-lm's `MLXHuggingFace` product is deliberately
*not* linked: it depends on `MLXFoundationModels`, a third-party `LanguageModel` over the executor ABI.


## A DMG to install from

```sh
./scripts/dmg.sh
```

Builds the Release configuration into `dist/DerivedData` (kept out of the shared one so the artefacts are the ones
that go into the image), stages `Savoia.app` next to a symlink to `/Applications`, and writes `dist/savoia-<version>.dmg`.
The version is `MARKETING_VERSION` read out of the project. Mount it, drag Savoia across, done.

The copy that goes into the image is stripped (`strip -rSTx`) and signed again with the entitlements the build
had: the binary goes from 92 MB to 49 MB and the app from 100 MB to 59 MB. Xcode strips only on install
(`DEPLOYMENT_POSTPROCESSING`), and an install build also drops `get-task-allow` whatever
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` says, which `scripts/profile.sh --attach` needs — so the script does it by
hand. The UUID does not change, so the dSYM in `dist/DerivedData` still names everything in a trace.

There is no signing identity on this machine (`security find-identity -v -p codesigning` finds none), so the app is
signed ad-hoc — the same "Sign to Run Locally" a Debug build gets. That is enough to install and run it *here*:
a DMG made locally carries no quarantine flag.

### Profiling the installed build

```sh
./scripts/profile.sh                        # 30 s of Time Profiler → dist/profiles/savoia-<timestamp>.trace
./scripts/profile.sh 60 'System Trace'      # seconds, then any name from `xcrun xctrace list templates`
./scripts/profile.sh --launch 60            # starts Savoia under the recording; quit it first
./scripts/profile.sh --attach 30 Allocations
./scripts/profile.sh --no-summary 600       # the trace alone
```

It records `/Applications/Savoia.app` (`SAVOIA_APP` names another copy) with `xctrace`, and the trace opens in
Instruments. Ctrl-C ends a recording before its time is up and
still saves it; a trace of every process grows by a few megabytes a second. Without a flag Savoia must already be
running, and is left alone. `--launch` wants it quit — a second
copy on the same Application Support directory traps in WebKit — and opens it once the recording has started, so the
launch is in the trace. `xctrace record --launch` is not used for that: given `Savoia.app` it finds the dev build and
the share extension as well and calls the path ambiguous.

A text summary is written beside the trace, `savoia-<timestamp>.txt` (`scripts/profile-summary.py`, which also runs
on its own against any Time Profiler trace): CPU by process and by minute, then self and inclusive time per function
for Savoia's main thread, its other threads, and the WebKit processes, and the hangs Instruments found. A trace of
every process exports its system frames as bare addresses and `xctrace symbolicate` does not help, since it looks
for dSYMs; the summary names them with `atos -p`, pointed at the Savoia that was recorded, then at Finder, because
`atos` names only what the process it is given has loaded. System libraries sit at the same addresses in every
process until the next reboot and no longer — the reason it is written straight after recording. An `--attach`
trace has the names already. The summary of a ten-minute trace of every process takes about seven minutes here.

Every process on the Mac is in the trace. Pages run in WebKit's `WebContent`, `GPU` and `Networking` processes,
which are Apple's and cannot be attached to with SIP on, and their parent is `launchd`, so there is no telling
Savoia's from Safari's by pid: quit other WebKit apps first, and filter by process in Instruments. `--attach` records
Savoia's own process alone, which is what the per-process templates (Allocations, Leaks) need.

Nothing is added to the build for either. `xcodebuild build` signs with `com.apple.security.get-task-allow`, which
is what `--attach` requires — hardened runtime without that entitlement would end it, and the script checks for it.
Release writes `dwarf-with-dsym`, and Instruments finds the dSYM in `dist/DerivedData` by UUID, so keep that folder
until the next `dmg.sh`.

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

The bundle's icon is an Icon Composer document, `Savoia/AppIcon.icon` (and `AppIcon-Dev.icon`, with the DEV band): a
full-bleed picture for light and one for dark, which `actool` compiles into `Assets.car` and the system draws, quit or
running, in the appearance it is in. Nothing is written onto the bundle, so the signature holds. `docs/logo.png` is
the light picture in its masked form, for the README. Both documents come from `scripts/appicon-variants.swift`, below.

The icons Configuration ▸ Appearance ▸ App Icon switches between are image sets (`IconSky`, `IconLight`, `IconDark`, `IconLightWings`,
`IconDarkWings`, and `Wings` for the start page), drawn by [`scripts/appicon-variants.swift`](../scripts/appicon-variants.swift)
from the pictures in `docs/icon-art/`:

```sh
swift scripts/appicon-variants.swift docs/icon-art Savoia/Assets.xcassets Savoia
```

`AppIconController` hands the chosen one to `NSApplication.applicationIconImage` at launch and when the appearance
changes; the development build gets its DEV
band drawn over it at run time. macOS has no alternate icons for an app that is not running, so a quit Savoia is drawn
from the bundle — the automatic wings — whatever was chosen. The choice used to be written onto the bundle as a custom
icon; that broke the seal of a signed bundle, and the controller removes what that left.

The development build's set carries an orange DEV band, so the two can be told apart in the Dock.

## Sandbox

App Sandbox is off — the ACP layer spawns `npx` / `claude` / `codex` from the user's toolchain.

