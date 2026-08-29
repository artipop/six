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
                // The SQLite half is measured and waiting on one piece of work, not forgotten —
                // see `docs/storage.md`. The files compile; `SQLiteData` does not, because it
                // depends unconditionally on `Sharing`, which is not portable (its own
                // `import Foundation.NSData` stops the build even after `combine-schedulers` is
                // patched). Linux takes `swift-structured-queries` directly plus the ~8-file
                // MIT bridge that binds it to GRDB, which keeps the same `DatabaseWriter` on both
                // platforms and leaves every call site here alone.
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
