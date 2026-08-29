// swift-tools-version: 6.0
import PackageDescription

// The Linux front, kept in a package of its own so the root one still builds on a Mac: SwiftPM has no
// way to leave a target out per platform, and a `pkgConfig: "webkitgtk-6.0"` target cannot resolve
// where there is no webkitgtk to find.
//
// `GtkSpike` is not the front. It is the half-day experiment the plan asks for before any of it is
// written — see docs/storage.md and the plan: does a WebKitWebView survive being moved around a
// GtkFixed, and does a click land in the column under the pointer when a bar is sitting on top of it.
let package = Package(
    name: "six-linux",
    dependencies: [.package(path: "..")],
    targets: [
        .systemLibrary(name: "CWebKitGTK", pkgConfig: "webkitgtk-6.0"),
        .executableTarget(name: "GtkSpike", dependencies: ["CWebKitGTK"])
    ]
)
