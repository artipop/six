# Platforms

six is two app targets in one project, over one set of sources:

| target | platform | product |
|---|---|---|
| `six` | macOS 27 | `six.app` |
| `six-iOS` | iOS / iPadOS 27, iPhone + iPad | `six.app` |

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
