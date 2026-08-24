Sources of https://github.com/anthropics/ClaudeForFoundationModels (main @ fd965bf, Apache-2.0), compiled directly into the
app target so they build against the same SDKROOT as the app (SwiftPM targets ignore the project's SDKROOT override).
`import ClaudeAPI` lines removed because both modules are merged into the app module. Replace with the SPM package once
Xcode's bundled SDK matches the OS beta.

Local edits: `ClaudeExecutor.swift` — `ClaudeAPI.Configuration.Auth` → `six.Configuration.Auth` (single-module build);
the app target sets `SWIFT_PACKAGE_NAME = six` so `package`-level declarations resolve.
