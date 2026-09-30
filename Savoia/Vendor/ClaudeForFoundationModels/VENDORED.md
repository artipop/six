Sources of https://github.com/anthropics/ClaudeForFoundationModels (main @ fd965bf, Apache-2.0), compiled directly into the
app target, which once pinned `SDKROOT` to the Command Line Tools SDK (SwiftPM targets ignore that override). The pin is
gone; replacing this tree with the SPM package is open. `import ClaudeAPI` lines removed because both modules are merged
into the app module.

Local edits: `ClaudeExecutor.swift` — `ClaudeAPI.Configuration.Auth` → `Savoia.Configuration.Auth` (single-module build);
the app target sets `SWIFT_PACKAGE_NAME = Savoia` so `package`-level declarations resolve. `RequestBuilder.swift` —
a `case .data` in the two transcript switches, for the cases the macOS 27.2 SDK added; both are dropped, as the
`@unknown default` beside them does.

Also local: every top-level declaration carries `nonisolated`. Upstream builds as a package of its own, where nothing
is isolated unless it says so; the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise
put this whole tree — value types, wire decoding, the executor Foundation Models calls off the main actor — on the
main actor, and say so a couple of dozen times per build. The keyword restores what the sources were written for, and
is the one edit to redo mechanically after a re-vendor.
