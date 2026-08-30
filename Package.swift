// swift-tools-version: 6.0
import PackageDescription

// The Linux entry point, and the place tests live.
//
// This package does not replace `six.xcodeproj` — it reads the same files where they lie. A target
// names its members in `sources:`, the way the iOS target names its exclusions in
// `membershipExceptions`, so a file belongs to a module by being listed rather than by being moved.
// `xcodebuild -project six.xcodeproj` ignores this manifest entirely.
//
// `SixCore` grows one directory at a time, and every addition has to keep `swift build` green on
// **Linux**, which is the only reason the package exists — building on macOS proves nothing the
// project didn't already know.
//
// `Package.resolved` here is **seeded from the app's own**
// (six.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) and that is load-bearing
// three times over. A database written by one build is opened by the other, so they had better agree
// on the library that wrote it. sqlite-data 1.11.0 does not compile against structured-queries 0.38,
// so a free resolve picks a set that does not build at all. And newer swift-sharing (2.10.0) and
// combine-schedulers (1.2.1) are Linux regressions — `package import Foundation.NSData` in one,
// `pthread_mutex_t` under a bare `import Foundation` in the other — arriving through SQLiteData,
// which depends on Sharing unconditionally.
//
// **So `swift package update` is a Linux-breaking command here.** Re-seed from the app instead, and
// let the project's own graph move first. See docs/storage.md.
let package = Package(
    name: "six",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SixCore", targets: ["SixCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        // No sqlite-vec here. Vectors are out of scope for the Linux phase, and its `CSQLiteVec`
        // reads the system SQLite headers while adwaita-swift's `meta-sqlite` vendors 3.51 — Clang
        // refuses two definitions of `sqlite3_api_routines` in one compilation. `AppDatabase` asks
        // for it with `#if canImport`, so the app keeps it and this build does without.
    ],
    targets: [
        .target(
            name: "SixCore",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data")
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
                // Domain names as they are written: the ACE form is what every platform's URL type
                // hands back, and deciding when it is safe to show the name behind it is the same
                // decision on all of them.
                "Browser/IDN.swift",
                "Browser/History.swift",
                // What a site was allowed. The decision, the queue and the suspension are the same
                // on both platforms; only the type the request arrives as differs, and that part
                // stays behind `#if canImport(WebKit)`.
                "Browser/SitePermissions.swift",
                // Translation. The engine is a seam — `Translation.framework` is Apple's, Linux
                // would use Bergamot and Android ML Kit — but the vocabulary, the JavaScript and
                // the batching are the same feature on every front, so they live here and are
                // built on Linux to prove it. `AppleTranslator` and the views are not.
                "Translation/TranslationSegment.swift",
                "Translation/TranslationBatch.swift",
                "Translation/TranslationScript.swift",
                "Translation/PageTranslator.swift"
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
            // GRDB directly, so a test can hand `SettingsStore` a database of its own rather than
            // the one under `AppSupport` that a running six is using.
            dependencies: ["SixCore", .product(name: "SQLiteData", package: "sqlite-data")],
            path: "Tests/SixCoreTests"
        )
    ]
)
