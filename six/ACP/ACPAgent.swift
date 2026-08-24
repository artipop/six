import Foundation

/// How to launch an ACP agent as a subprocess. Commands run through the login shell so PATH
/// customisations (nvm, homebrew, cargo) apply.
nonisolated struct ACPAgentDefinition: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String] = [:]

    var shellCommandLine: String {
        ([command] + arguments).map { arg in
            arg.rangeOfCharacter(from: .whitespaces) == nil ? arg : "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }

    /// Claude Code via Zed's ACP adapter (uses the local `claude` login).
    static let claudeCode = ACPAgentDefinition(
        id: "claude-code",
        name: "Claude Code",
        command: "npx",
        arguments: ["-y", "@zed-industries/claude-code-acp"]
    )

    /// OpenAI Codex via Zed's ACP adapter.
    static let codex = ACPAgentDefinition(
        id: "codex",
        name: "Codex",
        command: "npx",
        arguments: ["-y", "@zed-industries/codex-acp"]
    )

    static let builtIn: [ACPAgentDefinition] = [.claudeCode, .codex]
}

/// Runs an agent process and exposes its stdio as a JSON-RPC connection.
nonisolated final class ACPAgentProcess: @unchecked Sendable {
    let definition: ACPAgentDefinition
    let connection: JSONRPCConnection
    private let process: Process
    private let stderrPipe: Pipe
    private(set) var stderrLog: [String] = []
    private let lock = NSLock()

    init(definition: ACPAgentDefinition) throws {
        self.definition = definition
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec " + definition.shellCommandLine]
        var env = ProcessInfo.processInfo.environment
        // Claude Code refuses to start nested inside another Claude Code session; the agent is a separate session.
        env.removeValue(forKey: "CLAUDECODE")
        env.merge(definition.environment) { $1 }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stderrPipe = stderr
        connection = JSONRPCConnection(input: stdout.fileHandleForReading, output: stdin.fileHandleForWriting)
        try process.run()
        Task { await connection.start() }

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

    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        Task { await connection.close() }
        if process.isRunning { process.terminate() }
    }

    var recentStderr: String { lock.withLock { stderrLog.suffix(20).joined() } }
}
