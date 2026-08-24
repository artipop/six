import Foundation
import Observation

/// One rendered item in the agent transcript.
struct AgentTranscriptItem: Identifiable {
    enum Kind {
        case user(String)
        case agent(String)
        case thought(String)
        case toolCall(ACP.ToolCall)
        case plan([ACP.PlanEntry])
        case status(String)
    }
    let id: String
    var kind: Kind
}

/// A pending `session/request_permission` waiting for the user.
struct AgentPermissionPrompt: Identifiable {
    let id = UUID()
    let request: ACP.RequestPermissionRequest
    let respond: @Sendable (ACP.RequestPermissionOutcome) -> Void
}

/// View model: owns one `ACPClient` + one session, turns updates into a transcript.
@MainActor
@Observable
final class AgentSessionStore {
    enum State: Equatable {
        case idle, starting, ready, prompting, failed(String)
    }

    var agent: ACPAgentDefinition = .claudeCode {
        didSet { if agent != oldValue { disconnect() } }
    }
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser {
        didSet { if workingDirectory != oldValue { disconnect() } }
    }
    /// Optional model id passed to the agent (Claude Code reads `ANTHROPIC_MODEL`; Codex ignores it).
    var modelOverride: String = UserDefaults.standard.string(forKey: "six.agent.model") ?? "" {
        didSet {
            UserDefaults.standard.set(modelOverride, forKey: "six.agent.model")
            if modelOverride != oldValue { disconnect() }
        }
    }

    private(set) var state: State = .idle
    private(set) var transcript: [AgentTranscriptItem] = []
    private(set) var permissionPrompt: AgentPermissionPrompt?
    private(set) var modes: ACP.SessionModeState?
    private(set) var agentInfo: ACP.Implementation?
    private(set) var sessionId: String?

    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var delegateBox: DelegateBox?
    @ObservationIgnored private var openMessageID: String?
    @ObservationIgnored private var openThoughtID: String?

    var isConnected: Bool { client != nil && sessionId != nil }

    // MARK: Connection

    func connect() async {
        guard client == nil else { return }
        state = .starting
        transcript.removeAll()
        do {
            let box = DelegateBox(store: self)
            var definition = agent
            let model = modelOverride.trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { definition.environment["ANTHROPIC_MODEL"] = model }
            let client = try ACPClient(definition: definition, delegate: box)
            self.delegateBox = box
            self.client = client
            let info = try await client.initialize()
            agentInfo = info.agentInfo
            let session = try await client.newSession(cwd: workingDirectory)
            sessionId = session.sessionId
            modes = session.modes
            state = .ready
            append(.status("Connected to \(info.agentInfo?.title ?? info.agentInfo?.name ?? agent.name) · \(workingDirectory.path)"))
        } catch {
            let stderr = await client?.recentStderr ?? ""
            state = .failed(error.localizedDescription + (stderr.isEmpty ? "" : "\n\(stderr)"))
            disconnect(keepState: true)
        }
    }

    func disconnect(keepState: Bool = false) {
        let client = client
        Task { await client?.shutdown() }
        self.client = nil
        sessionId = nil
        modes = nil
        permissionPrompt = nil
        if !keepState { state = .idle }
    }

    // MARK: Prompting

    func send(_ text: String, context: [ACP.ContentBlock] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            if client == nil { await connect() }
            guard let client, let sessionId, state == .ready else { return }
            append(.user(text))
            openMessageID = nil
            openThoughtID = nil
            state = .prompting
            do {
                let stop = try await client.prompt(sessionId: sessionId, [.text(text)] + context)
                if stop != .endTurn { append(.status("Stopped: \(stop.rawValue)")) }
                state = .ready
            } catch {
                append(.status("Error: \(error.localizedDescription)"))
                state = .ready
            }
        }
    }

    func cancel() {
        guard let client, let sessionId else { return }
        Task { try? await client.cancel(sessionId: sessionId) }
    }

    func setMode(_ modeId: String) {
        guard let client, let sessionId else { return }
        Task {
            try? await client.setMode(sessionId: sessionId, modeId: modeId)
            modes?.currentModeId = modeId
        }
    }

    func resolvePermission(_ outcome: ACP.RequestPermissionOutcome) {
        permissionPrompt?.respond(outcome)
        permissionPrompt = nil
    }

    // MARK: Update handling

    fileprivate func handle(_ notification: ACP.SessionNotification) {
        guard notification.sessionId == sessionId else { return }
        switch notification.update {
        case .agentMessageChunk(let block):
            appendChunk(block.plainText ?? "", to: &openMessageID) { .agent($0) }
            openThoughtID = nil
        case .agentThoughtChunk(let block):
            appendChunk(block.plainText ?? "", to: &openThoughtID) { .thought($0) }
        case .userMessageChunk:
            break
        case .toolCall(let call):
            openMessageID = nil
            openThoughtID = nil
            if let index = transcript.firstIndex(where: { $0.id == "tool:\(call.toolCallId)" }) {
                transcript[index].kind = .toolCall(call)
            } else {
                transcript.append(.init(id: "tool:\(call.toolCallId)", kind: .toolCall(call)))
            }
        case .toolCallUpdate(let update):
            guard let index = transcript.firstIndex(where: { $0.id == "tool:\(update.toolCallId)" }),
                  case .toolCall(var existing) = transcript[index].kind else {
                transcript.append(.init(id: "tool:\(update.toolCallId)", kind: .toolCall(update)))
                return
            }
            if let v = update.title { existing.title = v }
            if let v = update.kind { existing.kind = v }
            if let v = update.status { existing.status = v }
            if let v = update.content { existing.content = v }
            if let v = update.locations { existing.locations = v }
            if let v = update.rawInput { existing.rawInput = v }
            if let v = update.rawOutput { existing.rawOutput = v }
            transcript[index].kind = .toolCall(existing)
        case .plan(let entries):
            if let index = transcript.lastIndex(where: { if case .plan = $0.kind { return true }; return false }) {
                transcript[index].kind = .plan(entries)
            } else {
                transcript.append(.init(id: "plan:\(UUID().uuidString)", kind: .plan(entries)))
            }
        case .currentModeUpdate(let modeId):
            modes?.currentModeId = modeId
        case .availableCommandsUpdate, .unknown:
            break
        }
    }

    fileprivate func requestPermission(_ request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            permissionPrompt = AgentPermissionPrompt(request: request) { outcome in
                guard resumed.trySet() else { return }
                continuation.resume(returning: outcome)
            }
        }
    }

    private func appendChunk(_ text: String, to openID: inout String?, make: (String) -> AgentTranscriptItem.Kind) {
        guard !text.isEmpty else { return }
        if let id = openID, let index = transcript.firstIndex(where: { $0.id == id }) {
            switch transcript[index].kind {
            case .agent(let existing): transcript[index].kind = .agent(existing + text)
            case .thought(let existing): transcript[index].kind = .thought(existing + text)
            default: break
            }
        } else {
            let id = UUID().uuidString
            transcript.append(.init(id: id, kind: make(text)))
            openID = id
        }
    }

    private func append(_ kind: AgentTranscriptItem.Kind) {
        transcript.append(.init(id: UUID().uuidString, kind: kind))
    }
}

/// Bridges the non-isolated delegate protocol onto the main-actor store.
private final class DelegateBox: ACPClientDelegate {
    nonisolated(unsafe) private weak var store: AgentSessionStore?
    init(store: AgentSessionStore) { self.store = store }

    func client(_ client: ACPClient, didReceive notification: ACP.SessionNotification) async {
        await MainActor.run { store?.handle(notification) }
    }

    func client(_ client: ACPClient, requestPermission request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        guard let store else { return .cancelled }
        return await store.requestPermission(request)
    }
}

nonisolated private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func trySet() -> Bool { lock.withLock { if value { return false }; value = true; return true } }
}
