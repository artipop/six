import Foundation

/// How to launch an ACP agent as a subprocess. Commands run with the user's shell environment
/// (`LoginShell`) so PATH customisations (nvm, homebrew, cargo) apply.
nonisolated struct ACPAgentDefinition: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var command: String
    var arguments: [String]
    var environment: [String: String] = [:]
    /// npm package that provides the adapter, and the executable it installs.
    var npmPackage: String
    var binaryName: String
    /// The underlying CLI the adapter drives (must be installed and logged in).
    var underlyingCLI: String
    var loginHint: String

    /// Same agent, launched through the globally installed binary instead of `npx`.
    func usingInstalledBinary() -> ACPAgentDefinition {
        var copy = self
        copy.command = binaryName
        copy.arguments = []
        return copy
    }

    var shellCommandLine: String {
        ([command] + arguments).map { arg in
            arg.rangeOfCharacter(from: .whitespaces) == nil ? arg : "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }

    /// Claude Code via the official ACP adapter (uses the local `claude` login).
    static let claudeCode = ACPAgentDefinition(
        id: "claude-code",
        name: "Claude Code",
        command: "npx",
        arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
        npmPackage: "@agentclientprotocol/claude-agent-acp",
        binaryName: "claude-agent-acp",
        underlyingCLI: "claude",
        loginHint: String(localized: "Install Claude Code and run `claude` once to log in.")
    )

    /// OpenAI Codex via the official ACP adapter.
    static let codex = ACPAgentDefinition(
        id: "codex",
        name: "Codex",
        command: "npx",
        arguments: ["-y", "@agentclientprotocol/codex-acp"],
        npmPackage: "@agentclientprotocol/codex-acp",
        binaryName: "codex-acp",
        underlyingCLI: "codex",
        loginHint: String(localized: "Install Codex CLI and run `codex login`.")
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

    /// `environment` is the user's shell environment (see `LoginShell`), so PATH customisations apply.
    init(definition: ACPAgentDefinition, environment: [String: String]) throws {
        self.definition = definition
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "exec " + definition.shellCommandLine]
        var env = environment
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
