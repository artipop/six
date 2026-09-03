import Foundation
import Observation

/// A pending `session/request_permission` waiting for the user.
struct AgentPermissionPrompt: Identifiable {
    let id = UUID()
    let request: ACP.RequestPermissionRequest
    let respond: @Sendable (ACP.RequestPermissionOutcome) -> Void
}

/// View model: owns one `ACPClient` + one session, turns updates into a transcript.
///
/// A conversation belongs to an agent in a folder (`AgentChat`): switching profile or agent switches
/// the chat on show, and every chat keeps its ACP session id so the agent can pick it up again with
/// `session/load` after a relaunch.
@MainActor
@Observable
final class AgentSessionStore {
    enum State: Equatable {
        case idle, starting, ready, prompting, failed(String)
    }

    var agent: ACPAgentDefinition = .claudeCode {
        didSet { if agent != oldValue { disconnect() } }
    }

    init(snapshot: AgentSnapshot? = nil, settings: SettingsStore) {
        self.settings = settings
        guard let snapshot else { return }
        if let saved = ACPAgentDefinition.builtIn.first(where: { $0.id == snapshot.agentID }) { agent = saved }
        chats = Dictionary(snapshot.chats.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var snapshot: AgentSnapshot {
        AgentSnapshot(agentID: agent.id, chats: chats.values.sorted { $0.key < $1.key })
    }

    // MARK: Chats

    /// Every conversation, by `AgentChat.key`.
    private(set) var chats: [String: AgentChat] = [:]
    /// The chat of the selected agent in the selected profile's folder — what the panel shows.
    var currentChatKey: String { AgentChat.key(agentID: agent.id, directoryPath: workingDirectory.path) }
    var transcript: [AgentTranscriptItem] { chats[currentChatKey]?.transcript ?? [] }
    /// The chat the live session writes to; the user may have switched profiles mid-turn.
    @ObservationIgnored private var liveChatKey: String?
    /// While `session/load` replays the history the agent's copy replaces ours.
    @ObservationIgnored private var isReplaying = false

    private var liveTranscript: [AgentTranscriptItem] {
        get { chats[liveChatKey ?? currentChatKey]?.transcript ?? [] }
        set { chats[chatKeyForWriting()]?.transcript = newValue }
    }

    private func chatKeyForWriting() -> String {
        let key = liveChatKey ?? currentChatKey
        if chats[key] == nil { chats[key] = AgentChat(agentID: agent.id, directoryPath: workingDirectory.path) }
        return key
    }

    /// Forgets the current chat and its session; the next prompt starts from nothing.
    func startNewChat() {
        let key = currentChatKey
        if liveChatKey == key { disconnect() }
        chats[key] = nil
    }
    /// Set once at launch; the working directory follows the selected profile.
    @ObservationIgnored weak var browser: BrowserState?

    /// The selected profile's folder (its own under Application Support unless the user chose one).
    var workingDirectory: URL {
        guard let browser else { return FileManager.default.homeDirectoryForCurrentUser }
        return browser.workingDirectory(for: browser.selectedProfile)
    }
    /// Directory the live session was created in; a different `workingDirectory` means reconnecting.
    @ObservationIgnored private var sessionDirectory: URL?
    @ObservationIgnored private let settings: SettingsStore
    /// Optional model id passed to the agent (Claude Code reads `ANTHROPIC_MODEL`; Codex ignores it).
    var modelOverride: String {
        get { settings.agentModel }
        set {
            guard newValue != settings.agentModel else { return }
            settings.agentModel = newValue
            disconnect()
        }
    }

    private(set) var state: State = .idle
    private(set) var permissionPrompt: AgentPermissionPrompt?
    private(set) var modes: ACP.SessionModeState?
    private(set) var agentInfo: ACP.Implementation?
    private(set) var sessionId: String?

    let toolchain = AgentToolchain()

    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var delegateBox: DelegateBox?
    @ObservationIgnored private var openMessageID: String?
    @ObservationIgnored private var openThoughtID: String?
    @ObservationIgnored private var openUserID: String?

    var isConnected: Bool { client != nil && sessionId != nil }

    // MARK: Connection

    /// `SIX_ACP_TRACE=1` in the environment mirrors the connection steps and every JSON-RPC line to stderr.
    nonisolated static let traces = ProcessInfo.processInfo.environment["SIX_ACP_TRACE"] != nil

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard traces else { return }
        FileHandle.standardError.write(Data("[acp] \(message())\n".utf8))
    }

    func connect() async {
        guard client == nil else { return }
        state = .starting
        let key = chatKeyForWriting()
        liveChatKey = key
        Self.trace("connect: \(agent.id) in \(workingDirectory.path)")
        do {
            let box = DelegateBox(store: self)
            if toolchain.report(for: agent).adapter == .unknown { await toolchain.refresh(agent) }
            var definition = toolchain.launchDefinition(for: agent)
            let model = modelOverride.trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { definition.environment["ANTHROPIC_MODEL"] = model }
            Self.trace("launching: \(definition.shellCommandLine)")
            let client = try await ACPClient(definition: definition, delegate: box)
            self.delegateBox = box
            self.client = client
            if Self.traces { await client.enableTrace() }
            let info = try await client.initialize()
            Self.trace("initialized: \(info.agentInfo?.name ?? "?")")
            agentInfo = info.agentInfo
            // The browser itself is offered as an MCP server (`six --mcp`), so the agent can drive it.
            let directory = workingDirectory
            let servers = [MCPStdioBridge.acpServer]
            let agentName = info.agentInfo?.title ?? info.agentInfo?.name ?? agent.name
            let savedSession = chats[key]?.sessionID
            if let savedSession, await resumeSession(savedSession, client: client, capabilities: info.agentCapabilities, cwd: directory, mcpServers: servers) {
                append(.status(String(localized: "Resumed session with \(agentName) · \(directory.path)")))
            } else {
                let session = try await client.newSession(cwd: directory, mcpServers: servers)
                sessionId = session.sessionId
                modes = session.modes
                chats[key]?.sessionID = session.sessionId
                append(.status(savedSession == nil
                    ? String(localized: "Connected to \(agentName) · \(directory.path)")
                    : String(localized: "Previous session couldn't be resumed; new session with \(agentName) · \(directory.path)")))
            }
            sessionDirectory = directory
            state = .ready
        } catch {
            let stderr = await client?.recentStderr ?? ""
            Self.trace("failed: \(error) \(stderr)")
            state = .failed(error.localizedDescription + (stderr.isEmpty ? "" : "\n\(stderr)"))
            disconnect(keepState: true)
        }
    }

    /// `session/load` with the saved id: the agent replays the conversation as `session/update`s, which
    /// replace our copy of the transcript. False when the agent can't load sessions or the id is gone
    /// (the saved transcript stays as a record of it).
    private func resumeSession(_ id: String, client: ACPClient, capabilities: ACP.AgentCapabilities?, cwd: URL, mcpServers: [ACP.MCPServer]) async -> Bool {
        guard capabilities?.loadSession == true, let key = liveChatKey else { return false }
        Self.trace("loading session \(id)")
        let backup = chats[key]?.transcript ?? []
        chats[key]?.transcript = []
        sessionId = id // updates for it arrive during the call
        isReplaying = true
        defer { isReplaying = false; openUserID = nil; openMessageID = nil; openThoughtID = nil }
        do {
            let response = try await client.loadSession(id: id, cwd: cwd, mcpServers: mcpServers)
            if let loaded = response?.modes { modes = loaded }
            return true
        } catch {
            Self.trace("load failed: \(error)")
            chats[key]?.transcript = backup
            sessionId = nil
            return false
        }
    }

    func disconnect(keepState: Bool = false) {
        let client = client
        Task { await client?.shutdown() }
        self.client = nil
        sessionId = nil
        sessionDirectory = nil
        liveChatKey = nil
        modes = nil
        permissionPrompt = nil
        if !keepState { state = .idle }
    }

    // MARK: Prompting

    /// What a prompt streams back to whoever asked (the ⌘K bar mirrors it).
    enum LiveUpdate {
        case text(String)       // the agent's message so far
        case activity(String)   // a tool call title
    }

    enum PromptOutcome: Equatable {
        case finished(ACP.StopReason)
        case failed(String)
    }

    @ObservationIgnored private var liveUpdate: ((LiveUpdate) -> Void)?

    /// What a running MCP app has to add to the next turn. Set by `MCPAppStore`.
    @ObservationIgnored var appContext: (() -> [ACP.ContentBlock])?

    func send(_ text: String, context: [ACP.ContentBlock] = []) {
        Task { await prompt(text, context: context) }
    }

    /// Sends a prompt and waits for the turn. Connects (or reconnects, when the agent or the profile
    /// folder changed) first; streams the agent's text through `onUpdate`.
    @discardableResult
    func prompt(_ text: String, context: [ACP.ContentBlock] = [], onUpdate: ((LiveUpdate) -> Void)? = nil) async -> PromptOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed(String(localized: "Empty prompt")) }
        if client != nil, let sessionDirectory, sessionDirectory != workingDirectory { disconnect() }
        if client == nil { await connect() }
        guard let client, let sessionId, state == .ready else {
            Self.trace("send dropped: client=\(self.client != nil) session=\(self.sessionId ?? "nil") state=\(state)")
            if case .failed(let message) = state { return .failed(message) }
            return .failed(String(localized: "The agent is busy"))
        }
        append(.user(text))
        openMessageID = nil
        openThoughtID = nil
        openUserID = nil
        liveUpdate = onUpdate
        state = .prompting
        defer { liveUpdate = nil }
        do {
            // What the running MCP apps want the model to know this turn (`ui/update-model-context`,
            // see docs/mcp-apps.md). Read once, here, because "next turn" is exactly this moment.
            let fromApps = appContext?() ?? []
            let stop = try await client.prompt(sessionId: sessionId, [.text(text)] + fromApps + context)
            if stop != .endTurn { append(.status(String(localized: "Stopped: \(stop.rawValue)"))) }
            state = .ready
            return .finished(stop)
        } catch {
            append(.status(String(localized: "Error: \(error.localizedDescription)")))
            state = .ready
            return .failed(error.localizedDescription)
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
            openUserID = nil
            if let id = openMessageID, let item = liveTranscript.first(where: { $0.id == id }), case .agent(let text) = item.kind {
                liveUpdate?(.text(text))
            }
        case .agentThoughtChunk(let block):
            appendChunk(block.plainText ?? "", to: &openThoughtID) { .thought($0) }
            openUserID = nil
        case .userMessageChunk(let block):
            // Only the history replay of `session/load` carries these; a live prompt is appended by `prompt`.
            guard isReplaying else { break }
            appendChunk(block.plainText ?? "", to: &openUserID) { .user($0) }
            openMessageID = nil
            openThoughtID = nil
        case .toolCall(let raw):
            openMessageID = nil
            openThoughtID = nil
            openUserID = nil
            // `mcp__six__open_window` is the wire's name for the tool; the panel shows `six open_window`.
            let call = Self.renamed(raw)
            liveUpdate?(.activity(call.title ?? call.kind?.rawValue ?? "tool"))
            if let index = liveTranscript.firstIndex(where: { $0.id == "tool:\(call.toolCallId)" }) {
                liveTranscript[index].kind = .toolCall(call)
            } else {
                liveTranscript.append(.init(id: "tool:\(call.toolCallId)", kind: .toolCall(call)))
            }
        case .toolCallUpdate(let rawUpdate):
            let update = Self.renamed(rawUpdate)
            guard let index = liveTranscript.firstIndex(where: { $0.id == "tool:\(update.toolCallId)" }),
                  case .toolCall(var existing) = liveTranscript[index].kind else {
                liveTranscript.append(.init(id: "tool:\(update.toolCallId)", kind: .toolCall(update)))
                return
            }
            if let v = update.title { existing.title = v }
            if let v = update.kind { existing.kind = v }
            if let v = update.status { existing.status = v }
            if let v = update.content { existing.content = v }
            if let v = update.locations { existing.locations = v }
            if let v = update.rawInput { existing.rawInput = v }
            if let v = update.rawOutput { existing.rawOutput = v }
            liveTranscript[index].kind = .toolCall(existing)
        case .plan(let entries):
            if let index = liveTranscript.lastIndex(where: { if case .plan = $0.kind { return true }; return false }) {
                liveTranscript[index].kind = .plan(entries)
            } else {
                liveTranscript.append(.init(id: "plan:\(UUID().uuidString)", kind: .plan(entries)))
            }
        case .currentModeUpdate(let modeId):
            modes?.currentModeId = modeId
        case .availableCommandsUpdate, .unknown:
            break
        }
    }

    fileprivate func requestPermission(_ raw: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome {
        var request = raw
        request.toolCall = Self.renamed(raw.toolCall)
        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            permissionPrompt = AgentPermissionPrompt(request: request) { outcome in
                guard resumed.trySet() else { return }
                continuation.resume(returning: outcome)
            }
        }
    }

    private func appendChunk(_ text: String, to openID: inout String?, make: (String) -> AgentTranscriptItem.Kind) {
        guard !text.isEmpty else { return }
        if let id = openID, let index = liveTranscript.firstIndex(where: { $0.id == id }) {
            switch liveTranscript[index].kind {
            case .agent(let existing): liveTranscript[index].kind = .agent(existing + text)
            case .thought(let existing): liveTranscript[index].kind = .thought(existing + text)
            case .user(let existing): liveTranscript[index].kind = .user(existing + text)
            default: break
            }
        } else {
            let id = UUID().uuidString
            liveTranscript.append(.init(id: id, kind: make(text)))
            openID = id
        }
    }

    /// The tool's name as the panel says it: the MCP mangling undone (`AgentToolName`).
    private static func renamed(_ call: ACP.ToolCall) -> ACP.ToolCall {
        guard let title = call.title else { return call }
        var copy = call
        copy.title = AgentToolName.display(title)
        return copy
    }

    private func append(_ kind: AgentTranscriptItem.Kind) {
        liveTranscript.append(.init(id: UUID().uuidString, kind: kind))
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
