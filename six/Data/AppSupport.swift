import Foundation

/// Where six keeps everything of its own: the database, the snapshot, the bookmarks, the thumbnails,
/// the MCP socket.
///
/// The folder is the bundle identifier — `Application Support/org.deffun.six`, and
/// `…/org.deffun.six.dev` for a Debug build, which carries an identifier of its own. That is the
/// convention for an app that keeps its own files, and it is doing real work here: the browser being
/// *worked on* can be launched, killed, rebuilt and relaunched all afternoon beside the browser being
/// *used*, and neither notices. They could not share anyway — the snapshot is rewritten whole, the
/// SQLite file is opened for writing, and there is one MCP socket at one path.
///
/// Nothing decides this; it falls out. Two identifiers are two folders, the way a sandboxed app gets
/// two containers for free, and there is no rule here to keep in step with the build settings.
///
/// Site data separates itself the same way: WebKit files a non-sandboxed app's cookies and storage
/// under `~/Library/WebKit/<bundle identifier>`, so a different identifier is a different browser as
/// far as every site is concerned. That is the point, and also the cost — a development six starts
/// logged out of everything. `docs/build.md` has the line that seeds it from the real one.
enum AppSupport {
    /// A build that is not the installed app. Read from the identifier rather than `#if DEBUG` so
    /// that the app, the `--mcp` bridge it spawns and anything else launched from the same bundle all
    /// answer the same way. Nothing about *paths* asks this — only whether to offer the web to a
    /// browser that is about to be killed and built again.
    static let isDevelopment = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    /// `~/Library/Application Support/<bundle identifier>`.
    static let root: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "org.deffun.six"
        return support.appending(path: identifier, directoryHint: .isDirectory)
    }()

    static func file(_ path: String) -> URL {
        root.appending(path: path)
    }

    static func folder(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }
}
