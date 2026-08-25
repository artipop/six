# Build

```sh
xcodebuild -project six.xcodeproj -scheme six -configuration Debug build
```

macOS 27 beta, Swift 5 language mode. Files are added to the target automatically (the project uses a synchronized
file group), so new sources need no project edits.

## SDK override

The target sets `SDKROOT` to the macOS 27 SDK from the **Command Line Tools** beta
(`/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`, build 26A5406c, FoundationModels 2.0.68 — the revision the
OS runtime ships) plus a `-plugin-path` for `SwiftUIMacros`. The installed Xcode carries an older SDK whose Foundation
Models *executor* ABI doesn't match the OS and crashes third-party `LanguageModel`s on launch. Drop both settings once
Xcode's own SDK matches the OS.

For the same reason `ClaudeForFoundationModels` is vendored into `six/Vendor/` and compiled into the app target: a
SwiftPM dependency would ignore the `SDKROOT` override.

## Sandbox

App Sandbox is off — the ACP layer spawns `npx` / `claude` / `codex` from the user's toolchain.
