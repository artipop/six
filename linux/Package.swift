// swift-tools-version: 6.2
import PackageDescription

// The Linux front, in a package of its own so the root one still builds on a Mac: SwiftPM cannot
// leave a target out per platform, and a `pkgConfig: "webkitgtk-6.0"` target cannot resolve where
// there is no webkitgtk to find.
//
// The UI is adwaita-swift. What is ours is the WebKitGTK interop, which no Swift GTK library covers
// — see `docs/linux.md` for why that split is the one that matters.
//
// Pinned to a commit rather than a tag: the only tag, 0.1.0, does not build on Linux (their #97),
// and the maintainer's advice is to live on main.
let package = Package(
    name: "six-linux",
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        // The vector index: `vec0` tables and the KNN the bookmarks are searched by, the same
        // dependency the Mac app links. Here rather than in the root manifest, and that is the
        // seam this package already enforces for `SixCore` itself — `CSQLiteVec` reads the system
        // SQLite headers while Adwaita's `meta-sqlite` vendors 3.51, and Clang refuses two
        // definitions of `sqlite3_api_routines` in one compilation unit. `SixBrowser` has no
        // Adwaita in it and imports this the way it imports `SixCore`: `internal`, so the module
        // never reaches `SixUI`. Naming it in the root manifest instead is what put it in front of
        // Adwaita and is why it was taken out again (7806432).
        .package(url: "https://github.com/mhayes853/sqlite-vec-data", from: "0.5.0"),
        // Transitive. sqlite-data declares swift-tagged unconditionally, SwiftPM prunes it while the
        // `Tagged` trait is off, and sqlite-vec-data turning that trait on does not un-prune it — the
        // resolve then fails with "exhausted attempts … 'swift-tagged' unresolved". Naming it does.
        .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
        .package(
            url: "https://codeberg.org/aparoksha/adwaita-swift",
            revision: "476f9e36d34239aed78ce141b8af435d8825c859"
        )
    ],
    targets: [
        .systemLibrary(name: "CWebKitGTK", pkgConfig: "webkitgtk-6.0"),
        // Ours, and ours whichever UI library wins: the profile's cookie jar, with no toolkit in it.
        .target(
            name: "SixWebKitCore",
            dependencies: ["CWebKitGTK"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The page as a widget adwaita can place.
        .target(
            name: "SixWebKit",
            dependencies: ["SixWebKitCore", "CWebKitGTK", .product(name: "Adwaita", package: "adwaita-swift")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The model. Deliberately without Adwaita: it depends on its own SQLite and SixCore reaches
        // GRDB's, and Clang will not have both in one compilation unit. The seam is enforced.
        .target(
            name: "SixBrowser",
            dependencies: [
                "SixWebKitCore",
                // By name as well as through `SixWebKitCore`, whose public API already hands out
                // `WebKitWebView *`: the script bridge and the off-screen page translation runs in
                // are written here, because this is the module that has `SixCore` — and Adwaita is
                // still nowhere near it, which is the seam the comment above is about.
                "CWebKitGTK",
                .product(name: "SixCore", package: "six"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "SQLiteVecData", package: "sqlite-vec-data")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(
            name: "SixUI",
            dependencies: [
                "SixWebKit",
                "SixWebKitCore",
                "SixBrowser",
                .product(name: "Adwaita", package: "adwaita-swift")
            ],
            // GTK is a single-threaded toolkit driven from one main loop, and `SixCore`'s stores are
            // `@MainActor` for the same reason on the Mac. Saying so once for the module beats
            // annotating every view — and it is what the Xcode project already sets with
            // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "six-linux",
            dependencies: ["SixUI"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
