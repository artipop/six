// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The Windows front, in a package of its own for the same reason linux/Package.swift is: SwiftPM
// cannot leave a target out per platform, and none of this resolves anywhere but on a machine with
// the Windows Swift toolchain.
//
// Deliberately plain Win32 (`WinSDK`, the module the toolchain itself ships) for the rail's own
// window rather than WinUI 3 + swift-winrt — see docs/windows.md for why. The engine is a different
// story: `CWebKit2` below is the real WebKit2 C API (the same family WebKitGTK's C API descends
// from), linked against the actual Playwright-built `WebKit2.dll` already proven working in
// `../sixty/windows/WebKitAdapter`'s MiniBrowserSwift. `vendor/WebKit2` holds the import library
// generated from that DLL's own export table (`WebKit2.def`/`.exp`/`.lib`) — not vendoring the DLL
// itself, which is large and already lives in the Playwright cache; see docs/windows.md for where
// the runtime picks it up from.
//
// No dependency on the root package at all — deliberately, and not the first thing this file tried.
// `SixCoreShared` below takes `NiriLayout`/`KeyBindings`/`KeyContext` straight out of `six/`, the
// same "a file joins a module by being listed" move the root Package.swift itself makes, one file
// list smaller: this front does not touch `AppDatabase`/`SettingsStore`/`Bookmark`/`History`, so it
// has no reason to compile them, and every reason not to — `SQLiteData` pulls in
// `swift-structured-queries`, whose keyPath dynamic-member-lookup subscripts (its core mechanism,
// used ~85 times) crash both official Windows Swift 6.3.3 toolchains this front was tried against.
// That is a confirmed, still-open upstream bug (swiftlang/swift#69386, filed 2023, Windows-specific
// constraint-solver assertion on `KeyPath` + `@dynamicMemberLookup`), not a version-pin problem —
// see docs/windows.md for the full account, including the two crash sites patched and confirmed
// working before the scale of the rest of them turned this into a "route around it" decision.
let webKit2LibDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("vendor/WebKit2")
    .path

let package = Package(
    name: "six-windows",
    targets: [
        // <windowsx.h>'s mouse/wheel macros, wrapped as the handful of inline functions Swift can
        // actually call. See the header for why they exist at all.
        .target(name: "CRailInterop"),
        // The WebKit2 C API's headers, adapted (by whoever built the matching WebKit2.dll) to avoid
        // <windows.h> types at the C boundary — a Clang-modules submodule-visibility issue under
        // Swift's ClangImporter — in favour of layout-compatible plain structs/`void *`, cast back to
        // HWND at the Swift call site. Header-only; `WebKit2.lib` (linked into six-windows below) is
        // what actually resolves the symbols.
        .target(name: "CWebKit2"),
        // The one piece of `SixCore` this front needs, with nothing else in its dependency graph —
        // no `SQLiteData`, no GRDB, no `swift-structured-queries`. SwiftPM will not let a target's
        // `path:` reach outside the package root (`../six` from here is "outside the package root"),
        // so `Sources/SixCoreShared` holds symlinks to the three real files in `six/`, not copies —
        // the same move `swift-structured-queries` itself makes for cross-target source sharing
        // (its "Symbolic Links" folders). One file, one source of truth, still. `.swiftLanguageMode(.v5)`
        // matches how the root Package.swift compiles these same files, so the source is being asked
        // the same question twice, not two different ones.
        .target(
            name: "SixCoreShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The model: `NiriLayout` plus the tab metadata the rail draws, no toolkit in it — the same
        // split `linux/Sources/SixBrowser` makes.
        .target(
            name: "SixBrowser",
            dependencies: ["SixCoreShared"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The rail itself: a Win32 window, GDI painting for the chrome, a real `WKView` per live
        // column for the page, and the mouse/wheel/keyboard input that drives all of it.
        .target(
            name: "SixUI",
            dependencies: ["SixBrowser", "CRailInterop", "CWebKit2"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "six-windows",
            dependencies: ["SixUI"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .unsafeFlags(["-L", webKit2LibDirectory, "-lWebKit2"])
            ]
            // `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` was tried here to drop the
            // console-subsystem default's auto-created console window (suspected of winning
            // keyboard focus away from the rail). A live test on the dev machine showed the window
            // stopped appearing at all under that link — not present even in Alt-Tab — so it is
            // reverted pending a real diagnosis. The actual keyboard fix was unrelated and stands:
            // Alt-held keys arrive as `WM_SYSKEYDOWN`, not `WM_KEYDOWN` (`RailWindow.handle`).
        )
    ]
)
