#if canImport(os)
import os
#endif
// `isatty` and `STDERR_FILENO` are C, and Foundation does not re-export them everywhere: Darwin on
// Apple, Glibc on Linux. Both spellings, because the file is compiled on both.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Where six says what happened.
///
/// ## Why this exists
///
/// Every diagnostic six had was `FileHandle.standardError.write(…)` — forty-five of them, in the
/// shape `[six] blocking: …`, which is a fine shape and goes nowhere. A Mac app is started by
/// LaunchServices, not by a shell: it has no terminal on the other end of file descriptor 2, so
/// everything six had to say about a failed save, a refused extension or a certificate that did not
/// check out was written into a pipe with nobody on the far side. The only way to read six was to
/// launch it from a terminal, which means quitting the browser you were trying to explain.
///
/// So: the two places a Mac application is expected to put this, and the one that was already here.
///
/// **The unified log.** `os.Logger`, subsystem is the bundle identifier, one category per area.
/// This is the platform's own answer — Console.app finds it, `log stream --predicate 'subsystem ==
/// "org.deffun.six"'` follows it live, `log show --last 1h` reads it back after the fact, and it
/// costs almost nothing when nobody is listening, because the formatting happens in the reader
/// rather than in six.
///
/// **A file**, `~/Library/Logs/<bundle identifier>/six.log`. The unified log is excellent and it
/// expires: entries age out on the system's schedule, which is hours to days, and a bug reported on
/// Thursday about Tuesday has nothing behind it. The file is the copy you can attach to a report,
/// `tail -f`, or read after six has crashed. `~/Library/Logs` is where a Mac app's log belongs —
/// Console.app lists it under Log Reports and every diagnostic-gathering tool already looks there.
///
/// **Standard error, when there is a terminal on it.** `isatty` decides. That is the workflow this
/// repository already has (`docs/build.md`: run the binary directly), and it costs one branch to
/// keep it working exactly as it did.
///
/// ## What it is not
///
/// Not a level system anyone tunes. All three levels go to all three places; what keeps the
/// tracers quiet is the environment variable their call site already checks (`SIX_UI_DEBUG`,
/// `SIX_LINKS_TRACE`, `SIX_MCP_TRACE`, …), which is where that decision was already being made and
/// is the only place that knows what it costs. The level is what a *reader* filters on — Console's
/// level menu, `log show --debug`, a `grep` over the file. A browser with a logging configuration
/// of its own is a browser with a second thing to get wrong.
///
/// Not private. The file records addresses — the one that failed to load is the whole point of the
/// line — and it sits in the user's own Library beside a history database and a snapshot that hold
/// far more. It rotates at four megabytes and keeps one generation, so it is bounded; delete it
/// like any other file if that matters. The unified log is marked `.public` for the same reason:
/// a diagnostic that reads `<private>` is not a diagnostic.
///
/// See [docs/logging.md](../../docs/logging.md).
nonisolated enum Log {
    /// The areas six talks about, which are the ones the `[six] <name>:` prefixes already named.
    /// Also the categories Console.app groups by, so this list is a user interface of a kind: keep
    /// it short enough to read in a filter menu.
    enum Category: String, CaseIterable, Sendable {
        case app
        case ui
        case pages
        case links
        case browser
        case load
        case blocking
        case certificates
        case extensions
        case bookmarks
        case embed
        case storage
        case profiles
        case history
        case documents
        case devtools
        case mcp
        case acp
        case keys
    }

    /// Something worth keeping: a save that failed, a decision six made on its own.
    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        write(category, .info, message())
    }

    /// Something that went wrong. Same destinations — the level is what a reader filters on, not a
    /// second policy about where it goes.
    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        write(category, .error, message())
    }

    /// A tracer: a line per key press, per link, per JSON-RPC frame. The call site is behind its
    /// own environment flag, so nothing here is what decides whether this is quiet.
    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        write(category, .debug, message())
    }

    enum Level: String, Sendable {
        case debug, info, error
    }

    // MARK: The three destinations

    private static func write(_ category: Category, _ level: Level, _ message: String) {
        #if canImport(os)
        // `.public` deliberately, and argued about above. The interpolation is still lazy: nothing
        // is formatted unless something is reading.
        let logger = logger(for: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        #endif
        let line = "\(timestamp()) [\(category.rawValue)]\(level == .error ? " error:" : "") \(message)\n"
        file.append(line)
        // The shape the terminal has always seen, unchanged, so nothing anyone greps for moves.
        if hasTerminal {
            FileHandle.standardError.write(Data("[six] \(category.rawValue): \(message)\n".utf8))
        }
    }

    #if canImport(os)
    /// One `Logger` per category, built once. A `Logger` is cheap but not free, and this is called
    /// from every diagnostic in the app.
    private static let loggers: [Category: Logger] = {
        let subsystem = Bundle.main.bundleIdentifier ?? "org.deffun.six"
        return Dictionary(uniqueKeysWithValues: Category.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        })
    }()

    private static func logger(for category: Category) -> Logger {
        loggers[category] ?? Logger(subsystem: "org.deffun.six", category: category.rawValue)
    }
    #endif

    /// Only when a person is looking at it. An app launched from Finder has a `/dev/null` here, and
    /// writing to it is the state this whole file exists to fix.
    private static let hasTerminal = isatty(STDERR_FILENO) != 0

    private static let file = LogFile()

    /// Local time to the millisecond, because the question a log answers is usually "what happened
    /// just before this". `ISO8601DateFormatter` has no milliseconds without options and no local
    /// time with them; this is one formatter, made once.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestamp() -> String {
        clock.string(from: Date())
    }

    // MARK: What the app offers to show

    /// The folder, for the button that reveals it and for anything that wants to attach the file.
    static var folder: URL { LogFile.folder }
    /// The file being written right now. The rotated generation is `six.previous.log` beside it.
    static var current: URL { LogFile.current }
}

/// The file half: open once, append from one queue, rotate when it gets big.
///
/// A serial queue rather than a lock, because these calls come from every actor six has and the
/// caller must not wait on a disk. The cost is that a crash can lose the last few lines — which is
/// exactly why the same line went to the unified log first, where it is already durable.
private nonisolated final class LogFile: Sendable {
    /// Four megabytes, then `six.log` becomes `six.previous.log` and a new one starts. Two
    /// generations is the whole policy: enough to survive a restart mid-investigation, small enough
    /// that nobody has to think about it on a machine with 8 GB and a browser on it.
    private static let limit = 4 * 1024 * 1024

    static let folder: URL = AppSupport.logs
    static let current: URL = folder.appending(path: "six.log")
    private static let previous: URL = folder.appending(path: "six.previous.log")

    private let queue = DispatchQueue(label: "org.deffun.six.log", qos: .utility)
    /// Nil until the first line, and nil again if the file cannot be opened at all — a browser does
    /// not stop working because its log does.
    nonisolated(unsafe) private var handle: FileHandle?
    nonisolated(unsafe) private var written = 0

    func append(_ line: String) {
        let data = Data(line.utf8)
        queue.async { [self] in
            guard let handle = openIfNeeded() else { return }
            try? handle.write(contentsOf: data)
            written += data.count
            if written >= Self.limit { rotate() }
        }
    }

    private func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: Self.current.path) {
            manager.createFile(atPath: Self.current.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: Self.current) else { return nil }
        // Appending, not truncating: a relaunch continues the same file, which is what makes "what
        // happened just before it died" answerable at all.
        written = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
        return opened
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let manager = FileManager.default
        try? manager.removeItem(at: Self.previous)
        try? manager.moveItem(at: Self.current, to: Self.previous)
    }
}
