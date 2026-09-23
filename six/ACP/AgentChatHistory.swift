#if os(macOS)
import Foundation
import Observation

/// Where a conversation goes when it is put aside: one JSON file per chat under `Chats/`.
///
/// Not the state file. That one is rewritten on every autosave, and a transcript is the biggest
/// thing six keeps — tool calls carry whole diffs — so the snapshot holds only what the list needs
/// (`AgentChat.summary`) and the text is read when somebody opens the chat.
nonisolated struct AgentChatArchive: Sendable {
    let folder: URL

    init(folder: URL = AppSupport.folder("Chats")) {
        self.folder = folder
    }

    private func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    func save(_ chat: AgentChat) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(chat).write(to: url(for: chat.id), options: .atomic)
        } catch {
            Log.error(.acp, "chat \(chat.id) not archived: \(error)")
        }
    }

    func load(_ id: UUID) -> AgentChat? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(AgentChat.self, from: data)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

/// The sessions an agent keeps for a folder, asked over `session/list`.
///
/// The agent's memory is longer than six's: it has the sessions started from its own CLI in the same
/// folder, and the ones six dropped before it kept a history at all. Asking is a process and a
/// handshake, like `AgentModelDiscovery`, so it is done when the history page is looked at and the
/// answer is kept for as long as six runs.
@MainActor @Observable
final class AgentSessionCatalog {
    private(set) var sessions: [String: [ACP.SessionInfo]] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Agents that answered `initialize` without offering `session/list`.
    private(set) var unsupported: Set<String> = []

    static func key(agent: ACPAgentDefinition, directory: URL) -> String { "\(agent.id)|\(directory.path)" }

    func sessions(for agent: ACPAgentDefinition, in directory: URL) -> [ACP.SessionInfo] {
        sessions[Self.key(agent: agent, directory: directory)] ?? []
    }

    func refresh(_ agent: ACPAgentDefinition, toolchain: AgentToolchain, directory: URL) async {
        let key = Self.key(agent: agent, directory: directory)
        guard !unsupported.contains(agent.id), loading.insert(key).inserted else { return }
        errors[key] = nil
        defer { loading.remove(key) }
        do {
            if toolchain.report(for: agent).adapter == .unknown { await toolchain.refresh(agent) }
            let client = try await ACPClient(definition: toolchain.launchDefinition(for: agent),
                                             delegate: SilentDelegate(), allowsFileAccess: false)
            let deadline = Task {
                try await Task.sleep(for: .seconds(30))
                await client.shutdown()
            }
            defer {
                deadline.cancel()
                Task { await client.shutdown() }
            }
            let info = try await client.initialize()
            guard info.agentCapabilities?.listsSessions == true else {
                unsupported.insert(agent.id)
                return
            }
            sessions[key] = try await client.listSessions(cwd: directory)
        } catch {
            errors[key] = error.localizedDescription
        }
    }
}

private final class SilentDelegate: ACPClientDelegate, Sendable {
    func client(_ client: ACPClient, didReceive notification: ACP.SessionNotification) async {}
    func client(_ client: ACPClient, requestPermission request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        .cancelled
    }
}
#endif
