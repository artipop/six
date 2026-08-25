import Foundation
import Observation

/// Checks whether an ACP adapter (and the CLI behind it) is available, and installs adapters with npm.
/// Everything runs with the interactive login-shell environment (`LoginShell`) so nvm/homebrew PATHs apply.
@MainActor
@Observable
final class AgentToolchain {
    enum AdapterStatus: Equatable {
        case unknown
        case checking
        /// Adapter binary is on PATH.
        case installed(path: String)
        /// npm is available; the adapter can be installed (or run via npx meanwhile).
        case installable(npmPath: String)
        /// No node/npm at all.
        case nodeMissing
    }

    struct Report: Equatable {
        var adapter: AdapterStatus = .unknown
        var underlyingCLIPath: String?
        var installLog = ""
        var isInstalling = false
    }

    static let nodeInstallURL = URL(string: "https://nodejs.org/en/download")!

    private(set) var reports: [ACPAgentDefinition.ID: Report] = [:]

    func report(for agent: ACPAgentDefinition) -> Report {
        reports[agent.id] ?? Report()
    }

    /// Launch definition for this agent: installed binary if present, otherwise `npx`.
    func launchDefinition(for agent: ACPAgentDefinition) -> ACPAgentDefinition {
        if case .installed = report(for: agent).adapter { return agent.usingInstalledBinary() }
        return agent
    }

    func refresh(_ agent: ACPAgentDefinition) async {
        reports[agent.id, default: Report()].adapter = .checking
        let names = [agent.binaryName, "npm", agent.underlyingCLI]
        let script = names.map { "command -v \($0) || echo ''" }.joined(separator: "; ")
        let output = (try? await Self.runLoginShell(script))?.output ?? ""
        let lines = output.components(separatedBy: "\n")
        func path(_ index: Int) -> String? {
            guard lines.indices.contains(index) else { return nil }
            let value = lines[index].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        var report = reports[agent.id] ?? Report()
        if let adapterPath = path(0) {
            report.adapter = .installed(path: adapterPath)
        } else if let npm = path(1) {
            report.adapter = .installable(npmPath: npm)
        } else {
            report.adapter = .nodeMissing
        }
        report.underlyingCLIPath = path(2)
        reports[agent.id] = report
    }

    func install(_ agent: ACPAgentDefinition) async {
        var report = reports[agent.id] ?? Report()
        report.isInstalling = true
        report.installLog = "$ npm install -g \(agent.npmPackage)\n"
        reports[agent.id] = report
        let result = try? await Self.runLoginShell("npm install -g \(agent.npmPackage) 2>&1")
        reports[agent.id]?.installLog += result?.output ?? "npm failed to start"
        reports[agent.id]?.isInstalling = false
        await refresh(agent)
    }

    // MARK: Shell

    private struct ShellResult { var status: Int32; var output: String }

    private static func runLoginShell(_ script: String) async throws -> ShellResult {
        let environment = await LoginShell.environment()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script]
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// The user's shell environment as a terminal would have it. A plain login shell (`zsh -l`) reads only
/// `.zprofile`, and nvm/bun/go typically live in `.zshrc`, so the PATH is taken from an interactive
/// login shell once and reused — commands then run in a non-interactive `zsh -c` with that environment,
/// keeping rc-file chatter off the agent's JSON-RPC pipe.
nonisolated enum LoginShell {
    private static let cache = Cache()

    static func environment() async -> [String: String] {
        if let cached = cache.value { return cached }
        let resolved = await Task.detached { resolve() }.value
        cache.value = resolved
        return resolved
    }

    private static func resolve() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE") // Claude Code refuses to run nested; the agent is its own session
        let marker = "__SIX_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", "echo \(marker); env"]
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return env }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let range = output.range(of: marker + "\n") else { return env }
        for line in output[range.upperBound...].split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            guard !key.isEmpty, key != "CLAUDECODE" else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: String]?
        var value: [String: String]? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
