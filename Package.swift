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
    targets: [
        .target(
            name: "SixCore",
            path: "six",
            sources: [
                // Geometry: no platform at all, and the piece a second front end reuses whole.
                "Niri/NiriLayout.swift",
                // Where six lives, and the versioned JSON snapshot beside the database.
                "Data/AppSupport.swift",
                "Persistence/SnapshotStore.swift",
                "Persistence/StatePersistence.swift"
                //
                // The SQLite half is measured and waiting on a decision, not forgotten — see
                // `docs/storage.md`. `Data/AppDatabase.swift` and `Bookmarks/Bookmark.swift` compile
                // fine, but `SQLiteData` depends unconditionally on `Sharing`, which reaches
                // `combine-schedulers`, which does not build on Linux under Swift 6.3. The way out
                // is `swift-structured-queries` directly — same `@Table` and `#sql` macros, no
                // `Sharing` — so the models travel unchanged and only `AppDatabase`'s plumbing
                // needs a Linux arm.
                //
                // Also not here: `Data/SettingsStore.swift` and, through it,
                // `Browser/{History,SearchEngine}.swift`. SettingsStore is the coupling hub of the
                // app — it decodes six subsystems' types out of the settings table (ModelChoice,
                // FilterList, InstalledExtension, SitePermissions, ResearchPreset, LivePageCache),
                // so taking it drags most of the app with it. Untangling that is its own step: each
                // typed accessor belongs beside the type it decodes, as an extension, leaving
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
