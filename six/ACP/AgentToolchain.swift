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
        /// The adapter's own version and the newest npm has. An adapter is not a thin shim over the
        /// CLI it is named after: it carries its own copy of it, so an old one goes on talking to
        /// the service with a year-old client. `codex-acp` 1.1.14 bundles Codex 0.147 and answers a
        /// request for today's model with "requires a newer version of Codex" — with Codex itself
        /// updated on the machine and nothing on screen to say which of the two was old.
        var installedVersion: String?
        var latestVersion: String?
        /// The version of the CLI the adapter is named after — `codex`, `claude` — which is a
        /// different number from the adapter's and the one a person has just updated by hand.
        var underlyingCLIVersion: String?

        var update: (from: String, to: String)? {
            guard let installedVersion, let latestVersion,
                  Report.isOlder(installedVersion, than: latestVersion) else { return nil }
            return (installedVersion, latestVersion)
        }

        /// Enough of semver for "is there something newer": numbers where both sides have them, and
        /// a pre-release is older than the release it is named after (1.12.1-preview.1 < 1.12.1).
        static func isOlder(_ one: String, than other: String) -> Bool {
            func parts(_ version: String) -> ([Int], Bool) {
                let release = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
                return (release.split(separator: ".").map { Int($0) ?? 0 }, version.contains("-"))
            }
            let (mine, minePre) = parts(one)
            let (theirs, theirsPre) = parts(other)
            for index in 0..<max(mine.count, theirs.count) {
                let a = index < mine.count ? mine[index] : 0
                let b = index < theirs.count ? theirs[index] : 0
                if a != b { return a < b }
            }
            return minePre && !theirsPre
        }
    }

    static let nodeInstallURL = URL(string: "https://nodejs.org/en/download")!

    private(set) var reports: [ACPAgentDefinition.ID: Report] = [:]

    func report(for agent: ACPAgentDefinition) -> Report {
        reports[agent.id] ?? Report()
    }

    /// Launch definition for this agent: installed binary if present, otherwise `npx`.
    func launchDefinition(for agent: ACPAgentDefinition) -> ACPAgentDefinition {
        guard agent.isBuiltIn else { return agent }
        if case .installed = report(for: agent).adapter { return agent.usingInstalledBinary() }
        return agent
    }

    func refresh(_ agent: ACPAgentDefinition) async {
        guard agent.isBuiltIn else { return }
        reports[agent.id, default: Report()].adapter = .checking
        let names = [agent.binaryName, "npm", agent.underlyingCLI]
        // One shell for all of it: three paths, then the adapter's version and the newest published.
        // `npm view` goes to the network, which is why this is not asked for on every launch — the
        // panel asks once, and the button beside the answer asks again.
        var script = names.map { "command -v \($0) || echo ''" }.joined(separator: "; ")
        script += "; (\(agent.binaryName) --version 2>/dev/null | tail -1) || echo ''"
        script += "; (npm view \(agent.npmPackage) version 2>/dev/null) || echo ''"
        script += "; (\(agent.underlyingCLI) --version 2>/dev/null | tail -1) || echo ''"
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
        // Each of them answers `--version` its own way: "@agentclientprotocol/codex-acp 1.12.0",
        // "2.0.71 (Claude Code)", a bare number. The version is the first thing in the line that
        // looks like one — the last word gave "Code)" for Claude.
        report.installedVersion = Self.version(in: path(3))
        report.latestVersion = path(4)
        report.underlyingCLIVersion = Self.version(in: path(5))
        reports[agent.id] = report
    }

    /// The first `1.2.3`-shaped word in a line, if there is one.
    private static func version(in line: String?) -> String? {
        guard let line else { return nil }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()[]v")) }
            .first { word in
                let parts = word.split(separator: ".")
                return parts.count >= 2 && parts.allSatisfy { $0.first?.isNumber == true }
            }
    }

    func install(_ agent: ACPAgentDefinition) async {
        var report = reports[agent.id] ?? Report()
        report.isInstalling = true
        // Always `@latest`: this is the update button as well as the install one, and npm asked for
        // a package it already has at any version does nothing at all.
        report.installLog = "$ npm install -g \(agent.npmPackage)@latest\n"
        reports[agent.id] = report
        let result = try? await Self.runLoginShell("npm install -g \(agent.npmPackage)@latest 2>&1")
        // An install that worked has nothing to say: the version beside the adapter's name is the
        // whole report, and npm's twelve lines about funding are not. The log is kept for the other
        // case, where it is the only thing that says what went wrong.
        if result?.status == 0 {
            reports[agent.id]?.installLog = ""
        } else {
            reports[agent.id]?.installLog += result?.output ?? "npm failed to start"
        }
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
