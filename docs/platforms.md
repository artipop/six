# Platforms

six is two app targets in one Xcode project over one set of sources, a third front end on Linux built
by SwiftPM over the same files, and a fourth in Kotlin that shares no code with any of them:

| target | platform | built by | product |
|---|---|---|---|
| `six` | macOS 27 | `six.xcodeproj` | `six.app` |
| `six-iOS` | iOS / iPadOS 27, iPhone + iPad | `six.xcodeproj` | `six.app` |
| `six-linux` | Linux, GTK 4 + WebKitGTK 6.0 | `linux/Package.swift` | `six-linux` |
| `six-android` | Android 14+, Compose + system WebView | `android/` (Gradle) | `org.deffun.six` |

This page is about the two Apple targets; the third has [linux.md](linux.md) and the fourth
[android.md](android.md). The first three share `SixCore` — the layout, the database, the settings —
and the file it writes. The fourth shares only the file, the schema and the arithmetic, which is why
its page spends most of its length on what "the same" has to mean without a shared compiler.

```sh
xcodebuild -project six.xcodeproj -scheme six-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation -skipPackagePluginValidation build
```

Both targets take the whole `six/` synchronized folder, so a new file joins both without a project
edit — the same as before. What the phone leaves out is a list of exceptions on the folder
(`membershipExceptions` in the project file), not a second copy of anything.

## Why two targets and not one

Xcode builds one target for several platforms happily, but only when `SDKROOT` can be `auto`, and
six's cannot: the Mac needs the Command Line Tools SDK, because Xcode's own Foundation Models
executor SPI does not match the OS ([build.md](build.md#sdk-override)). Compiled against Xcode's
macOS SDK the app does not build at all — `RequestBuilder`, `EventTranslator` and
`ClaudeServerToolActivity` in the vendored `ClaudeForFoundationModels` fail on `GeneratedContent`.
`SDKROOT` is resolved before any `[sdk=…]` condition can be evaluated, so it cannot differ per
platform inside one target. Two targets, one `SDKROOT` each.

When Xcode's SDK catches up with the OS, this collapses back into one target with two destinations,
and the exception list becomes `#if os(macOS)` like everything else.

## What the phone does not have

Excluded from `six-iOS`, in the project file:

- **`ACP/`** — everything but the wire types. The agent layer launches `claude` / `codex` as child
  processes and speaks JSON-RPC over their stdio; iOS has no `Process` and no toolchain to run.
  `ACPJSON`, `ACPTypes` and `AgentTranscript` stay: the browser tools are written in the first, and
  the state file is written in the others, on both platforms.
- **`MCP/`** — the server six runs for those agents, over a Unix socket and over `--mcp` stdio.
- **`Research/ResearchCoordinator.swift`** — deep research is the agent driving the browser.
  `ResearchRun` stays, so the phone reads and writes back that part of the state file untouched.
- **`Vendor/ClaudeForFoundationModels`** — the SDK mismatch above; the iOS SDK is Xcode's by
  definition. So the assistant on the phone is the on-device model and Private Cloud Compute;
  `ModelChoice` has the Claude and ACP cases only on macOS, and a setting saved on the Mac and read
  on the phone falls back to on-device.
- **`Views/AgentPanel.swift`** — the panel for the session that isn't there.

Everything else is shared, with `#if os(macOS)` where the two frameworks spell the same thing
differently ([Platform/](../six/Platform)) or where a thing is genuinely a Mac's: the menu bar
(`Views/MacCommands.swift`), the window restoration, the `NSEvent` scroll monitor, `NSOpenPanel` and
`NSSavePanel`, "Show in Finder".

## The layout, turned

The niri model is one-dimensional: columns follow one another *along* the strip, workspaces stack
*across* it. Which screen direction that runs in is the view's business, so the device turns it
without the model knowing ([layout.md](layout.md)):

| | along the strip | across it |
|---|---|---|
| Mac, and any device on its side | left → right | up / down |
| any device held upright | top → bottom | left / right |

The strip wants the screen's long edge to run along it, so the axis is the viewport's own shape —
`size.height > size.width` — and nothing else. Size classes would answer a different question: an
iPad is `.regular` whichever way it is held, which would leave it in the Mac's layout upright.

`StripAxis.stripSpace` hands `NiriLayout.updateViewport` the viewport along-first, so every width,
gap and scroll offset it already computes comes back as the extent to draw down the screen. Turning
the device re-measures and recentres; nothing in the model moves.

The Mac drives the strip with ⌥ + scroll, because over a page a gesture belongs to the page. A phone
has no modifier to hold, so the strip is driven from its own chrome: the handle above each window
pans along the strip, and across it switches workspace. The drag feeds `NiriLayout`'s
`horizontalPreview` / `verticalPreview` — the same rubber band the Mac's scroll monitor writes — and
letting go either commits a step or springs back; nothing rests half-way. Inside the page every
gesture is still the page's.

The handle is also where the address is typed: a phone has no ⌘L and no room for a bar of its own,
so a tap on the window that already has focus turns its title into the field. A tap on any other
window just brings it to focus, so walking the strip never opens the keyboard.

An empty rail says the same thing here as on the Mac — the icon, **New Window**, and nothing else:
the `⌘T` the Mac names underneath is not an offer a phone can make, and the `+` in the toolbar is the
other way to the same window. Since `closeTab` stopped opening a window in place of the last one
closed, this is the screen a phone lands on after closing everything, and without it that screen
would be blank.

## The buttons at the ends

The Mac keeps its two edge slivers out of sight and answers a pointer resting on one by leaning the
whole strip aside — the peek, [layout.md](layout.md). That is a pointer idea: it is asked for by
*resting* somewhere, and a finger has nowhere to rest, it is touching or it is not. So `PhoneStripView`
draws them where they stand: `‹ ›` at the two ends of the focused window, turned to `∧ ∨` when the
strip runs down the screen, and a `+` at whichever end the strip has run out of — the same two
answers `StripEdgeButton.step` gives, with the arrow facing along the strip instead of across it.

This is what `SettingsStore.peeksAtEdges` being **off** looks like, and why it defaults off away from
macOS. Touch deliberately does not read the flag: honouring an "on" would leave the strip with no
button anything could reach.

The gap the glyph sits in is about a tenth of a finger, so the target reaches out of it — 44 points,
Apple's minimum and the same order as the handle's own close button — and overlaps the rounded
corners it stands between. At the ends of the screen it is clamped by half its own width, which is
why the leading arrow sits a little inside the window rather than in the gap above it.

## Not there yet

- Extension popups and extension permission prompts (`ExtensionStore`): the Mac puts up an
  `NSPopover` and an `NSAlert`; the phone logs and declines.
- Installing an extension from a file: no file panel, and no `ditto` to unpack an archive with.
- Save As writes into the app's Documents folder instead of asking where.
- The overview button toggles `isOverview`, which on the phone only rescales the strip — there is no
  grid behind it yet.

Run on the simulator (iOS 27 runtime): iPhone 17 Pro and iPad Pro 11-inch, both from a seeded
`state.json` — the strip, the start page, page loading, persistence and the localisation all come
up, upright and on the side. There is no Simulator.app in this Xcode, so a device cannot be rotated:
the landscape axis was checked by pinning `UISupportedInterfaceOrientations_iPad` to landscape for
one build (with `UIRequiresFullScreen`, without which iPadOS ignores the restriction). Gestures —
the drag along and across the handle — are still unexercised, for the same missing-GUI reason.

The edge buttons were checked the same way, by seeding `state.json` and reading the screen back
(`simctl io … screenshot`): one window shows `+` at both ends, the middle of three shows `‹ ›`, and
the last of three shows a step back and a `+` ahead. With the keyboard up the strip is wider than it
is tall and the axis turns with it, which is how both orientations came out of one device.

**Build it with a destination, not an SDK.** `-sdk iphonesimulator` hands the simulator platform to
the SwiftPM macro plugins as well, which then cannot run as host tools — the compiler reports
`StructuredQueriesSQLiteMacros … produced malformed response` and every `@Table` in the app fails.
`-destination 'generic/platform=iOS Simulator'` builds them for the host and the target compiles.
