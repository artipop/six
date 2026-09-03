Sources of https://github.com/anthropics/ClaudeForFoundationModels (main @ fd965bf, Apache-2.0), compiled directly into the
app target so they build against the same SDKROOT as the app (SwiftPM targets ignore the project's SDKROOT override).
`import ClaudeAPI` lines removed because both modules are merged into the app module. Replace with the SPM package once
Xcode's bundled SDK matches the OS beta.

Local edits: `ClaudeExecutor.swift` — `ClaudeAPI.Configuration.Auth` → `six.Configuration.Auth` (single-module build);
the app target sets `SWIFT_PACKAGE_NAME = six` so `package`-level declarations resolve.

Also local: every top-level declaration carries `nonisolated`. Upstream builds as a package of its own, where nothing
is isolated unless it says so; the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise
put this whole tree — value types, wire decoding, the executor Foundation Models calls off the main actor — on the
main actor, and say so a couple of dozen times per build. The keyword restores what the sources were written for, and
is the one edit to redo mechanically after a re-vendor.
