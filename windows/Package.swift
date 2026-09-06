// swift-tools-version: 6.2
import PackageDescription

// The Windows front, in a package of its own for the same reason linux/Package.swift is: SwiftPM
// cannot leave a target out per platform, and none of this resolves anywhere but on a machine with
// the Windows Swift toolchain.
//
// Deliberately plain Win32 (`WinSDK`, the module the toolchain itself ships) rather than WinUI 3 +
// swift-winrt. The prototype this front was grown out of, `../sixty`, already has a working WinUI
// window — but it needs a NuGet-fed codegen step, the Windows App SDK and a handful of submodules
// resolved before six's own code compiles at all, and its own plan doc flags the projection as slow
// to regenerate and easy to dirty. `docs/windows.md` has the tradeoff in full; the short version is
// that "the build should also pass on Windows" is a bar Win32 clears with nothing beyond the
// toolchain, and WinUI does not yet.
let package = Package(
    name: "six-windows",
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        // <windowsx.h>'s mouse/wheel macros, wrapped as the handful of inline functions Swift can
        // actually call. See the header for why they exist at all.
        .target(name: "CRailInterop"),
        // The model: `NiriLayout` plus the tab metadata the rail draws, no toolkit in it — the same
        // split `linux/Sources/SixBrowser` makes, minus the parts (a real `WebView`, history,
        // bookmarks) this front does not have yet. See docs/windows.md for what that leaves out.
        .target(
            name: "SixBrowser",
            dependencies: [
                .product(name: "SixCore", package: "six")
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // The rail itself: a Win32 window, GDI painting, and the mouse/wheel input that drives it.
        .target(
            name: "SixUI",
            dependencies: ["SixBrowser", "CRailInterop"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "six-windows",
            dependencies: ["SixUI"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
