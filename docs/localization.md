# Localization

Every string a person reads is localized; every string a *model* reads is not. That line is the whole design.

- **People**: menus, panels, sheets, help tags, status lines, the names of the default profiles, "Untitled". These
  live in `six/Localizable.xcstrings` — one String Catalog, English as the source language, Russian shipped next to
  it. `six/InfoPlist.xcstrings` carries what the system shows on six's behalf: the camera / microphone / location
  prompts and the document type names in the Finder.
- **Models**: `BrowserToolCatalog.instructions`, every tool `description` and parameter description, the research
  preset, the errors a tool hands back (`BrowserTool.Failure`). They stay English, because they are a prompt, not an
  interface — and a page's own text arrives in whatever language it was written in either way.

The one thing that crosses the line is a tool's `title` — see [mcp.md](mcp.md#names): it is the display name a client
shows to a human, so it is localized.

## How a string gets into the catalog

SwiftUI takes string literals as `LocalizedStringKey` already, so `Button("Close Window")` needs nothing. Anything
that computes a `String` — a status line, an enum's `title`, a value handed to `Text(_:)` as a variable, an
`NSOpenPanel`'s `message` — must say so:

```swift
var title: String {
    switch self {
    case .profile: String(localized: "This Profile")
    case .all: String(localized: "All Profiles")
    }
}
```

`SWIFT_EMIT_LOC_STRINGS` is on, so the compiler writes every such key into `.stringsdata` next to the object files.
After a build, fold them into the catalog:

```sh
D=$(ls -d ~/Library/Developer/Xcode/DerivedData/six-*/Build/Intermediates.noindex/six.build/Debug/six.build/Objects-normal/arm64)
xcrun xcstringstool sync six/Localizable.xcstrings --stringsdata "$D"/*.stringsdata
```

(`xcstringstool` comes from the Xcode toolchain — `/Applications/Xcode*.app/Contents/Developer/usr/bin/` — so
`xcode-select -p` must point at Xcode, not at the Command Line Tools; otherwise call it by its full path.) New keys
appear with `"extractionState": "stale"` cleared and no translation; keys that no longer occur in the source are
marked stale. Opening the catalog in Xcode does the same thing through the UI.

## Counting

A count in a sentence is a plural entry, in *both* languages. English needs `one` / `other`; Russian needs all four
(`one` окно, `few` окна, `many` окон, `other` окна), and the catalog compiles each into
`<code>.lproj/Localizable.stringsdict`.

The source language is not exempt. `^[\(count) windows](inflect: true)` — Foundation's automatic grammar agreement —
looks like it saves the English side, but nothing resolves the markup when there is no table for the language: the
string reaches the screen as the literal `^[3 windows](inflect: true)`. So the keys are plain (`%lld windows`) and
English carries its own two plural forms, like every other language.

Because of that, **never build a countable phrase by concatenation**. A sentence with a count in the middle is
composed from two localized pieces instead, each with its own plural rules:

```swift
"\(layout.title(at: index)) · \(String(localized: "\(workspace.columns.count) windows"))"
```

## Adding a language

1. Add the code to `knownRegions` in `six.xcodeproj/project.pbxproj` (`en`, `Base`, `ru` today).
2. Add a `localizations` entry per key in both catalogs.
3. Build: `xcodebuild` compiles each language into `six.app/Contents/Resources/<code>.lproj/`.

The system's own menus (Edit, Window, Help, the services) follow automatically once the language is in the bundle —
they come from AppKit, not from six.

To see the app in a language without changing the system:

```sh
./six.app/Contents/MacOS/six -AppleLanguages '(ru)'
```

## What is deliberately not translated

- Engine and model names — `DuckDuckGo`, `Google`, `Claude Opus 5`, `Codex (ACP)`.
- Tool *names* on the wire (`open_window`) — they are identifiers an agent types, and the panel shows them as they
  are called ([mcp.md](mcp.md#names)).
- Anything an agent or a page wrote: a transcript, a document, a page title, a bookmark's saved text.
- `six` itself.
