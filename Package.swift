// swift-tools-version: 6.0
import PackageDescription

// The Linux entry point, and the place tests live.
//
// This package does not replace `six.xcodeproj` — it reads the same files where they lie. A target
// names its members in `sources:`, the way the iOS target names its exclusions in
// `membershipExceptions`, so a file belongs to a module by being listed rather than by being moved.
// `xcodebuild -project six.xcodeproj` ignores this manifest entirely.
//
// `SixCore` is the part that already imports nothing but Foundation and Observation. It grows one
// directory at a time, and every addition has to keep `swift build` green on **Linux**, which is the
// only reason the package exists — building on macOS proves nothing the project didn't already know.
let package = Package(
    name: "six",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SixCore", targets: ["SixCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        .package(url: "https://github.com/mhayes853/sqlite-vec-data", from: "0.5.0"),

        // Pins, not uses. Neither is imported anywhere in six; both are here to hold the graph at
        // the versions the app itself resolved, because the newer ones do not build on Linux:
        //
        //   swift-sharing 2.10.0    `package import Foundation.NSData` — no such module off Apple
        //   combine-schedulers 1.2.1  `pthread_mutex_t` under a bare `import Foundation`
        //
        // Both are regressions (2.9.1, 2.8.2 and 2.5.2 of Sharing all build clean), both are
        // upstream, and both arrive through SQLiteData, which depends on Sharing unconditionally.
        // Keeping the two builds on the same versions is worth having anyway: a database written by
        // one is opened by the other.
        //
        // **So bumping either of these is a Linux-breaking change**, and it will break in a package
        // six never imports. See docs/storage.md.
        .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.9.1"),
        .package(url: "https://github.com/pointfreeco/combine-schedulers", exact: "1.2.0")
    ],
    targets: [
        .target(
            name: "SixCore",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "SQLiteVecData", package: "sqlite-vec-data")
            ],
            path: "six",
            sources: [
                // Geometry: no platform at all, and the piece a second front end reuses whole.
                "Niri/NiriLayout.swift",
                // Where six lives, and the versioned JSON snapshot beside the database.
                "Data/AppSupport.swift",
                "Persistence/SnapshotStore.swift",
                "Persistence/StatePersistence.swift",
                "Data/AppDatabase.swift",
                "Data/SettingsStore.swift",
                "Bookmarks/Bookmark.swift",
                "Browser/SearchEngine.swift",
                "Browser/History.swift"
                //
                // `SettingsStore` is in only because it was untangled first: it used to decode six
                // subsystems' types out of the settings table, so taking it would have dragged most
                // of the browser behind it. Each typed accessor now lives beside the type it
                // decodes, and what is left here knows only keys and strings.
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SixCoreTests",
            dependencies: ["SixCore"],
            path: "Tests/SixCoreTests"
        )
    ]
)
