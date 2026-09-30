// swift-tools-version: 6.0
import PackageDescription

// The place tests live. This package does not replace `Savoia.xcodeproj` — it reads the same files
// where they lie: a file belongs to `SavoiaCore` by being listed in `sources:` rather than by being
// moved, and `xcodebuild` ignores this manifest entirely.
//
// `Package.resolved` here is seeded from the app's own and must agree with it on GRDB, sqlite-data
// and swift-structured-queries (docs/storage.md). `swift build` and `swift test` resolve first and
// rewrite it, so pass **`--disable-automatic-resolution`** to every one of them:
//
//   swift test --disable-automatic-resolution
let package = Package(
    name: "savoia",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SavoiaCore", targets: ["SavoiaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.11.0"),
        // No sqlite-vec here: `AppDatabase` asks for it with `#if canImport`, so the app keeps it
        // and the tests do without.
    ],
    targets: [
        .target(
            name: "SavoiaCore",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data")
            ],
            path: "Savoia",
            sources: [
                "Tiling/TilingLayout.swift",
                "Input/KeyBindings.swift",
                "Input/KeyContext.swift",
                "Data/AppSupport.swift",
                "Data/FormerName.swift",
                "Data/Log.swift",
                "Persistence/SnapshotStore.swift",
                "Persistence/StatePersistence.swift",
                "Data/AppDatabase.swift",
                "Data/ConfigurationStore.swift",
                "Bookmarks/Bookmark.swift",
                "Bookmarks/TextChunker.swift",
                "Bookmarks/VectorIndex.swift",
                "Bookmarks/Embedder.swift",
                "Bookmarks/BookmarkIndexer.swift",
                "Bookmarks/BookmarkSelfTest.swift",
                "Bookmarks/ReadablePage.swift",
                "Bookmarks/BookmarkFile.swift",
                "Bookmarks/Embedding/EmbeddingCatalog.swift",
                "Bookmarks/Embedding/EmbeddingStore.swift",
                "Bookmarks/Embedding/EmbedderDriver.swift",
                "Bookmarks/Embedding/WebEmbedder.swift",
                "Browser/WindowSwitcher.swift",
                "Tabs/TabTopics.swift",
                "Tabs/TabCleanup.swift",
                "Tabs/GroupColor.swift",
                "Browser/SearchEngine.swift",
                "Browser/PageSandbox.swift",
                "Browser/IDN.swift",
                "Browser/ExternalScheme.swift",
                "Browser/History.swift",
                "Browser/ProfileStore.swift",
                "Browser/SitePermissions.swift",
                "Translation/TranslationSegment.swift",
                "Translation/TranslationBatch.swift",
                "Translation/TranslationScript.swift",
                "Translation/PageTranslator.swift",
                "Translation/TranslationSettings.swift",
                "Translation/LanguageGuess.swift",
                "Translation/Payload/BergamotGlue.swift",
                "Translation/Bergamot/Checksum.swift",
                "Translation/Bergamot/BergamotCatalog.swift",
                "Translation/Bergamot/BergamotStore.swift",
                "Translation/Bergamot/BergamotDriver.swift",
                "Translation/Bergamot/BergamotRuntime.swift",
                "Translation/Bergamot/BergamotTranslator.swift",
                "ACP/ACPJSON.swift",
                "ACP/AgentModels.swift",
                "ACP/JSONRPCError.swift",
                "MCP/Client/MCPAppTypes.swift",
                "MCP/Client/MCPRegistry.swift",
                "MCP/Client/MCPOAuth.swift",
                "WebMCP/WebMCPRegistry.swift",
                "WebMCP/WebMCPBroker.swift",
                "WebMCP/WebMCPForms.swift",
                "WebMCP/WebMCPScript.swift",
                "WebMCP/WebMCPHost.swift",
                "WebMCP/WebMCPPage.swift",
                "WebMCP/WebMCPSelfTest.swift"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SavoiaCoreTests",
            // GRDB directly, so a test can hand `ConfigurationStore` a database of its own rather than
            // the one under `AppSupport` that a running Savoia is using.
            dependencies: ["SavoiaCore", .product(name: "SQLiteData", package: "sqlite-data")],
            path: "Tests/SavoiaCoreTests"
        )
    ]
)
