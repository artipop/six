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
    /// Attributed so the command in it is set in monospace rather than shown between backticks.
    var loginHint: AttributedString
    var loginCommand: String? = nil

    /// Same agent, launched through the globally installed binary instead of `npx`.
    func usingInstalledBinary() -> ACPAgentDefinition {
        var copy = self
        copy.command = binaryName
        copy.arguments = []
        return copy
    }

    var shellCommandLine: String {
        ([command] + arguments).map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
    }

    /// Claude Code via the official ACP adapter (uses the local `claude` login).
    static let claudeCode = ACPAgentDefinition(
        id: "claude-code",
        name: "Claude Code",
        command: "npx",
        // `@latest`, because `npx -y <package>` reuses whatever version its cache happens to hold:
        // the adapter carries its own copy of the CLI it drives, and a stale one breaks against
        // today's models while the CLI on the machine is current (see `AgentToolchain.Report`).
        arguments: ["-y", "@agentclientprotocol/claude-agent-acp@latest"],
        npmPackage: "@agentclientprotocol/claude-agent-acp",
        binaryName: "claude-agent-acp",
        underlyingCLI: "claude",
        loginHint: AttributedString(localized: "Open Terminal and run `claude` to sign in to Claude Code."),
        loginCommand: "claude"
    )

    /// OpenAI Codex via the official ACP adapter.
    static let codex = ACPAgentDefinition(
        id: "codex",
        name: "Codex",
        command: "npx",
        arguments: ["-y", "@agentclientprotocol/codex-acp@latest"],
        npmPackage: "@agentclientprotocol/codex-acp",
        binaryName: "codex-acp",
        underlyingCLI: "codex",
        loginHint: AttributedString(localized: "Open Terminal and run `codex login` to sign in to Codex."),
        loginCommand: "codex login"
    )

    static let builtIn: [ACPAgentDefinition] = [.claudeCode, .codex]

    var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }
}

extension ConfigurationStore {
    var customAgents: [ACPAgentDefinition] {
        get { decode(.customAgents) ?? [] }
        set { encode(.customAgents, newValue) }
    }

    var selectedCustomAgent: ACPAgentDefinition? {
        customAgents.first { $0.id == self[.selectedCustomAgent] } ?? customAgents.first
    }

    func model(for agent: ACPAgentDefinition) -> String {
        let models: [String: String] = decode(.agentModels) ?? [:]
        return models[agent.id] ?? (agent.id == ACPAgentDefinition.claudeCode.id ? agentModel : "")
    }

    func setModel(_ model: String, for agent: ACPAgentDefinition) {
        var models: [String: String] = decode(.agentModels) ?? [:]
        models[agent.id] = model
        encode(.agentModels, models)
    }

    /// The model list `AgentModelDiscovery` last managed to ask for, by agent — asking again means a
    /// process spawned and an ACP handshake run just to read a name off it, so a picker opened twice
    /// shows the second time from here, not from a second wait.
    var agentModelCatalogs: [String: AgentModels] {
        get { decode(.agentModelCatalogs) ?? [:] }
        set { encode(.agentModelCatalogs, newValue) }
    }
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
