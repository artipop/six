import Foundation

/// Runs an MCP server as a subprocess and exposes its stdio as a JSON-RPC connection.
///
/// The same shape as `ACPAgentProcess`, and for the same reason: both ends of six's MCP — the
/// browser answering an agent, and the browser asking a server — speak newline-delimited JSON-RPC
/// over `JSONRPCConnection`.
///
/// **Not through a shell.** `ACPAgentProcess` runs `zsh -c exec …`, and can: its command lines are
/// six's own constants. A server's command line is not — it comes from a person typing, or from a
/// registry entry somebody else published, and the registry's own schema spells out why that
/// matters: *"a malicious argument value like `;rm -rf ~/Development` could execute dangerous
/// commands… clients should prefer non-shell execution methods"*. So the program is resolved
/// against the login shell's `PATH` (which is the only thing the shell was ever needed for — nvm,
/// homebrew) and spawned directly, with its arguments as arguments. There is no string for anything
/// to be injected into.
nonisolated final class MCPServerProcess: @unchecked Sendable {
    let definition: MCPServerDefinition
    let connection: JSONRPCConnection
    private let process: Process
    private let stderrPipe: Pipe
    private var stderrLog: [String] = []
    private let lock = NSLock()

    init(definition: MCPServerDefinition, environment: [String: String]) throws {
        self.definition = definition
        var env = environment
        env.merge(definition.environment) { $1 }
        guard let executable = Self.resolve(definition.command, in: env) else {
            throw JSONRPCError.internalError("\(definition.command) is not on the PATH")
        }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = definition.arguments
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stderrPipe = stderr
        connection = JSONRPCConnection(input: stdout.fileHandleForReading, output: stdin.fileHandleForWriting)
        try process.run()
        Task { await connection.start() }

        // A server's stderr is its log, not its protocol; kept for the diagnostics line and nothing
        // else, and bounded so a chatty server cannot grow the app.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock {
                self.stderrLog.append(text)
                if self.stderrLog.count > 200 { self.stderrLog.removeFirst(self.stderrLog.count - 200) }
            }
        }
    }

    var isRunning: Bool { process.isRunning }
    var recentStderr: String { lock.withLock { stderrLog.suffix(20).joined() } }

    /// Where a bare program name lives, according to the environment six was given. A name with a
    /// slash in it is a path already and is taken as written.
    private static func resolve(_ command: String, in environment: [String: String]) -> URL? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let url = URL(fileURLWithPath: command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        Task { await connection.close() }
        if process.isRunning { process.terminate() }
    }
}
