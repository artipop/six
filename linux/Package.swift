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
        // The toolkit layer, and the only module that knows what GTK is. Everything above it —
        // the strip, the columns, the browser model — sees `Widget`, `WebView`, `NetworkSession`
        // and nothing else, which is what makes swapping the toolkit later cost one module.
        .target(name: "SixGtk", dependencies: ["CWebKitGTK"]),
        // The front. Thin on purpose: this is the module a declarative layer would replace, so the
        // investment stays in SixCore above it and SixGtk below it.
        .target(name: "SixUI", dependencies: ["SixGtk", .product(name: "SixCore", package: "six")]),
        .executableTarget(name: "six-linux", dependencies: ["SixUI"]),
        .executableTarget(name: "GtkSpike", dependencies: ["CWebKitGTK"])
    ]
)
