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
// directory at a time, and every addition has to keep `swift build` green on Linux.
let package = Package(
    name: "six",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SixCore", targets: ["SixCore"])
    ],
    dependencies: [
        // Versions follow the project's own resolved graph
        // (six.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved), so the two
        // builds compile the same sources against the same libraries.
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        .package(url: "https://github.com/mhayes853/sqlite-vec-data", from: "0.5.0")
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
                // The SQLite half. This is the part `docs/todo.md` flags as the unverified one:
                // SQLiteData does not declare Linux in its manifest, so whether it builds there is
                // the question the Linux target exists to answer early.
                "Data/AppDatabase.swift",
                "Bookmarks/Bookmark.swift"
                //
                // Deliberately not here yet: `Data/SettingsStore.swift` and, through it,
                // `Browser/{History,SearchEngine}.swift`. SettingsStore is the coupling hub of the
                // app — it decodes six subsystems' types out of the settings table (ModelChoice,
                // FilterList, InstalledExtension, SitePermissions, ResearchPreset, LivePageCache),
                // so taking it drags most of the app with it. Untangling that is its own step:
                // each typed accessor belongs beside the type it decodes, as an extension, leaving
                // SettingsStore itself knowing only keys and strings.
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
