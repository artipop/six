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
//
// And `swift build`/`swift test` are quietly the same command: they resolve first, and a resolve on
// macOS rewrites this file — the `originHash` changes and the pins nothing on this platform needs
// (OpenCombine, which only Linux pulls in) are dropped, so the next Linux build resolves from
// scratch. Pass **`--disable-automatic-resolution`** to every one of them:
//
//   swift test --disable-automatic-resolution
//
// It builds from the pins as written and fails loudly if they cannot satisfy the manifest, which is
// exactly the promise this file is here to make. `--skip-update` is not it: that only skips the
// fetch, and still writes.
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
                // The keyboard, minus the window system. A binding is a key's name, the modifiers a
                // hand can hold, where it may answer and what it does — and `KeyBindingsTests` reads
                // docs/hotkeys.md and checks the table against it in both directions, which is the
                // only thing that has ever stopped that file drifting. Turning an `NSEvent` into
                // those values is `Input/KeyEvents.swift`, and that one stays in the app.
                "Input/KeyBindings.swift",
                "Input/KeyContext.swift",
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
                // Who the profiles are. The row and the table are plain values and plain SQL, and
                // the reason they exist at all — that the identity every other table is keyed by
                // must not live in a file that can fail to decode — is the same on every front.
                "Browser/ProfileStore.swift",
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
                "Translation/PageTranslator.swift",
                // The wire, and only the wire. JSON-RPC's own two types, the shape of an MCP
                // server's answers, and the registry that lists servers: text in, values out, no
                // window and no process. What six *does* with an app — the scheme handler, the
                // session, the store — is WebKit and AppKit and stays in the app target. This much
                // is the same conversation on any platform, and it is the half worth a test.
                "ACP/ACPJSON.swift",
                "ACP/JSONRPCError.swift",
                "MCP/Client/MCPAppTypes.swift",
                "MCP/Client/MCPRegistry.swift",
                "MCP/Client/MCPOAuth.swift"
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
