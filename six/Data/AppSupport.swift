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
nonisolated enum AppSupport {
    /// A build that is not the installed app. Read from the identifier rather than `#if DEBUG` so
    /// that the app, the `--mcp` bridge it spawns and anything else launched from the same bundle all
    /// answer the same way. Nothing about *paths* asks this — only whether to offer the web to a
    /// browser that is about to be killed and built again.
    static let isDevelopment = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false

    /// `~/Library/Application Support/<bundle identifier>` on Apple, `$XDG_DATA_HOME/six` on Linux,
    /// `%LOCALAPPDATA%\six` on Windows.
    ///
    /// The one function a port has to answer differently: everything else in the app reaches its
    /// files through `file(_:)` and `folder(_:)` below, so this is the whole of "where six lives".
    /// Linux is spelled out rather than left to Foundation — `.applicationSupportDirectory` does
    /// resolve there, but to `~/.local/share` without the `XDG_DATA_HOME` override a Linux user
    /// expects to be honoured, and `Bundle.main.bundleIdentifier` is nil off Apple, so the folder
    /// would be named by the fallback anyway.
    ///
    /// Windows is spelled out for the second of those reasons and one of its own: Foundation's
    /// `.applicationSupportDirectory` lands in `%APPDATA%`, the *roaming* profile, which a domain
    /// account synchronises between machines at sign-in. A browser's SQLite file and its WebKit
    /// storage are exactly what must not be copied around behind an open handle, and Windows'
    /// answer for a program's own working files is the local profile.
    static let root: URL = {
        #if os(Windows)
        let base: URL
        if let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty {
            base = URL(fileURLWithPath: local, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: "AppData/Local", directoryHint: .isDirectory)
        }
        return base.appending(path: "six", directoryHint: .isDirectory)
        #elseif os(Linux)
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: ".local/share", directoryHint: .isDirectory)
        }
        return base.appending(path: "six", directoryHint: .isDirectory)
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "org.deffun.six"
        return support.appending(path: identifier, directoryHint: .isDirectory)
        #endif
    }()

    /// Where the log goes: `~/Library/Logs/<bundle identifier>` on Apple — the folder every Mac app
    /// writes its own log into, the one Console.app lists under Log Reports, and the one every
    /// diagnostic-gathering tool already knows to look in — and `$XDG_STATE_HOME/six` on Linux,
    /// which is where that spec puts the state a program keeps between runs and nobody configures.
    ///
    /// Deliberately not under `root`. A log is not application *support*: it is not backed up with
    /// the browser's data, it is not migrated, and deleting it costs nothing — which is exactly the
    /// distinction the two folders exist to draw. See `Log`.
    static let logs: URL = {
        #if os(Windows)
        // `%LOCALAPPDATA%\six\Logs`, beside the database rather than under it: Windows has no
        // convention of its own for a program's log — the Event Log is for the system's business,
        // not a browser's — and the local profile is where a program's own working files go, which
        // is the same argument `root` makes above. Spelled out here because Foundation's
        // `.libraryDirectory` is an Apple idea and answers on Windows with something between wrong
        // and nothing; asking it for `[0]` was one empty array away from a crash on first log line.
        return root.appending(path: "Logs", directoryHint: .isDirectory)
        #elseif os(Linux)
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: ".local/state", directoryHint: .isDirectory)
        }
        return base.appending(path: "six", directoryHint: .isDirectory)
        #else
        // The app's own container on the phone, `~/Library` on the Mac: `.libraryDirectory` is the
        // one that answers both correctly, and the bundle identifier separates the development
        // build from the real browser here as it does everywhere else.
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "org.deffun.six"
        return library.appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: identifier, directoryHint: .isDirectory)
        #endif
    }()

    static func file(_ path: String) -> URL {
        root.appending(path: path)
    }

    static func folder(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }
}
