import Foundation

/// A second connection to the person's agent for small jobs nobody watches, so they never land in the
/// chat. Each question gets a fresh session in its own folder inside six's.
@MainActor
final class AgentErrands {
    static let directory = AppSupport.folder("Agents/Errands")
    private static let idleShutdown: Duration = .seconds(300)

    private var client: ACPClient?
    private var agentID: String?
    private let listener = Listener()
    private var idle: Task<Void, Never>?
    private var queue: Task<String, Error>?

    /// The agent's reply, text only; tools are refused.
    func ask(_ prompt: String, agent: ACPAgentDefinition) async throws -> String {
        let previous = queue
        let task = Task { [weak self] () throws -> String in
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.run(prompt, agent: agent)
        }
        queue = task
        return try await task.value
    }

    private func run(_ prompt: String, agent: ACPAgentDefinition) async throws -> String {
        idle?.cancel()
        defer { scheduleShutdown() }
        let client = try await connected(agent)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let session = try await client.newSession(cwd: Self.directory)
        listener.start(session.sessionId)
        _ = try await client.prompt(sessionId: session.sessionId, text: prompt)
        return listener.finish()
    }

    private func connected(_ agent: ACPAgentDefinition) async throws -> ACPClient {
        if let client, agentID == agent.id { return client }
        await client?.shutdown()
        client = nil
        let fresh = try await ACPClient(definition: agent, delegate: listener, allowsFileAccess: false)
        _ = try await fresh.initialize()
        client = fresh
        agentID = agent.id
        return fresh
    }

    private func scheduleShutdown() {
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.idleShutdown)
            guard !Task.isCancelled, let self else { return }
            await self.client?.shutdown()
            self.client = nil
        }
    }
}

nonisolated private final class Listener: ACPClientDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session = ""
    private var text = ""

    func start(_ session: String) { lock.withLock { self.session = session; text = "" } }
    func finish() -> String { lock.withLock { text.trimmingCharacters(in: .whitespacesAndNewlines) } }

    func client(_ client: ACPClient, didReceive notification: ACP.SessionNotification) async {
        guard case .agentMessageChunk(.text(let chunk)) = notification.update else { return }
        lock.withLock { if notification.sessionId == session { text += chunk } }
    }

    func client(_ client: ACPClient, requestPermission request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        .cancelled
    }
}
