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
    targets: [
        .target(
            name: "SixCore",
            path: "six",
            sources: [
                "Niri/NiriLayout.swift"
            ]
        ),
        .testTarget(
            name: "SixCoreTests",
            dependencies: ["SixCore"],
            path: "Tests/SixCoreTests"
        )
    ]
)
