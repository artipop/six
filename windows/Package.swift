// swift-tools-version: 6.2
import Foundation
import PackageDescription

// A package of its own for the same reason `linux/Package.swift` is one: SwiftPM cannot leave a
// target out per platform, and none of this resolves anywhere but on a Windows toolchain.
//
// No package dependencies at all, deliberately, and not the first thing tried. Depending on the
// root package's `SixCore` drags in `SQLiteData` → `swift-structured-queries`, whose keyPath
// dynamic-member-lookup subscripts crash `swift-frontend` on both official Windows toolchains this
// was tried against — swiftlang/swift#69386, open since 2023. `SixCoreShared` below takes the three
// files this front actually needs straight out of `six/` instead; docs/windows.md has the account.
let webKit2LibDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("vendor/WebKit2")
    .path

let package = Package(
    name: "six-windows",
    targets: [
        .target(name: "CRailInterop"),
        // The WebKit2 C API's headers, adapted (by whoever built the matching WebKit2.dll) to keep
        // <windows.h> types off the C boundary — they trip a Clang-modules submodule-visibility
        // issue under ClangImporter — in favour of layout-compatible structs and `void *`.
        // Header-only; `vendor/WebKit2/WebKit2.lib`, linked below, resolves the symbols.
        .target(name: "CWebKit2"),
        // SwiftPM will not let a target's `path:` reach outside the package root, so
        // `Sources/SixCoreShared` holds symlinks to the real files in `six/`, not copies — the same
        // cross-target source sharing `swift-structured-queries` does with its own "Symbolic Links"
        // folders. `.v5` so these files are asked the same question the root package asks them.
        .target(
            name: "SixCoreShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SixBrowser",
            dependencies: ["SixCoreShared"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
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
            // `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` — to drop the console-subsystem
            // default's console window — made the rail window stop appearing at all, not even in
            // Alt-Tab. Reverted pending a diagnosis; see docs/windows.md.
        )
    ]
)
