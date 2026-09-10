// swift-tools-version: 6.2
import Foundation
import PackageDescription

// A package of its own for the same reason `linux/Package.swift` is one: SwiftPM cannot leave a
// target out per platform, and none of this resolves anywhere but on a Windows toolchain.
//
// It depends on the root package the way the Linux front does, and that is newer than the file's
// first version, which had no package dependencies at all. What changed is the toolchain, not the
// code: `swift-structured-queries`' keyPath dynamic-member-lookup subscripts trip an *assertion*
// in `swift-frontend`, and swift.org ships only assertions-enabled toolchains for Windows, so what
// reads as a platform bug is a compiler-variant one — the same source builds on macOS and Linux
// because those toolchains are built with `NDEBUG`. Built by the `+NoAsserts` toolchain that ships
// inside the same swift.org installer, the whole graph compiles and runs. `scripts/six-windows.ps1`
// finds that toolchain, and `docs/windows.md` has the measurements.
let webKit2LibDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("vendor/WebKit2")
    .path

let package = Package(
    name: "six-windows",
    dependencies: [
        // Named, unlike `linux/Package.swift`'s bare `.package(path: "..")`: a path dependency takes
        // its identity from the *directory*, and this checkout is `six-main` rather than `six`, so
        // `package: "six"` below would not resolve without saying so here.
        .package(name: "six", path: ".."),
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        // The vector index, the same one the Mac app links: `vec0` virtual tables and the KNN the
        // bookmarks are searched by. Named here rather than in the root manifest on purpose — the
        // root one is compiled on Linux too, where `CSQLiteVec` reads the system SQLite headers
        // while adwaita-swift's `meta-sqlite` vendors its own, and Clang will not hold two
        // definitions of `sqlite3_api_routines` in one compilation unit. Windows has no Adwaita and
        // no such collision, so the dependency lives at the front that can afford it and `SixCore`
        // stays free of it. `linux/Package.swift` does the same thing behind the same seam.
        .package(url: "https://github.com/mhayes853/sqlite-vec-data", from: "0.5.0"),
        // Transitive, and named for the same reason combine-schedulers is: without it the resolve
        // fails outright with "exhausted attempts … 'swift-tagged' unresolved". sqlite-data declares
        // swift-tagged unconditionally but SwiftPM prunes it while the `Tagged` trait is off, and
        // sqlite-vec-data turning that trait on is not enough to bring it back. Naming it here is.
        // It costs a "dependency is not used by any target" warning, which is true and is the price.
        .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
        // Transitive — it arrives through SQLiteData → Sharing → swift-dependencies — and named
        // here only to hold it at the one version the mirror in `.swiftpm/configuration` carries.
        // Every released version of this package assumes `import Foundation` brings pthreads along,
        // true on Linux and false on Windows, so it cannot compile here unpatched; UPSTREAM.md §4
        // is the report, and the mirror points at a local clone of 1.2.0 with the SRWLOCK branch
        // applied. Without the `exact:`, a free resolve would take 1.2.2 from upstream and fail.
        .package(url: "https://github.com/pointfreeco/combine-schedulers", exact: "1.2.0")
    ],
    targets: [
        .target(name: "CRailInterop"),
        // The WebKit2 C API's headers, adapted (by whoever built the matching WebKit2.dll) to keep
        // <windows.h> types off the C boundary — they trip a Clang-modules submodule-visibility
        // issue under ClangImporter — in favour of layout-compatible structs and `void *`.
        // Header-only; `vendor/WebKit2/WebKit2.lib`, linked below, resolves the symbols.
        .target(name: "CWebKit2"),
        .target(
            name: "SixBrowser",
            dependencies: [
                .product(name: "SixCore", package: "six"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "SQLiteVecData", package: "sqlite-vec-data")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "SixUI",
            // `SixCore` directly as well as through `SixBrowser`, because this is where the shared
            // page-facing code is used rather than wrapped: the translation state machine, the page
            // script, `PageSandbox`. `SixBrowser` keeps its own import `internal` so that the model
            // does not re-export it, which is why naming it again here is not redundant.
            dependencies: [
                "SixBrowser", "CRailInterop", "CWebKit2",
                .product(name: "SixCore", package: "six")
            ],
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
