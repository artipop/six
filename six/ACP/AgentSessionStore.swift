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
/// `session/load` after a relaunch. A new chat puts the old one aside rather than forgetting it
/// (`past`, and its transcript in `AgentChatArchive`), and `open` brings one back.
@MainActor
@Observable
final class AgentSessionStore {
    enum State: Equatable {
        case idle, starting, ready, prompting, failed(String)
    }

    var agent: ACPAgentDefinition = .claudeCode {
        didSet { if agent != oldValue { disconnect() } }
    }

    init(snapshot: AgentSnapshot? = nil, settings: ConfigurationStore) {
        self.settings = settings
        modelDiscovery = AgentModelDiscovery(store: settings)
        guard let snapshot else { return }
        if let saved = (ACPAgentDefinition.builtIn + settings.customAgents).first(where: { $0.id == snapshot.agentID }) { agent = saved }
        chats = Dictionary(snapshot.chats.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var snapshot: AgentSnapshot {
        AgentSnapshot(agentID: agent.id, chats: chats.values.sorted { $0.key < $1.key }, past: past)
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
        set {
            let key = chatKeyForWriting()
            chats[key]?.transcript = newValue
            // The replay of `session/load` is the conversation as it was, not something said now.
            if !isReplaying { chats[key]?.updatedAt = Date() }
        }
    }

    private func chatKeyForWriting() -> String {
        let key = liveChatKey ?? currentChatKey
        if chats[key] == nil { chats[key] = AgentChat(agentID: agent.id, directoryPath: workingDirectory.path) }
        return key
    }
        past = snapshot.past ?? []

    /// Puts the current chat aside with its session; the next prompt starts from nothing, and the
    /// old one is in the history (`six://chats`) to be opened again.
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
    @ObservationIgnored private let settings: ConfigurationStore
    /// Model preferences belong to each agent, and are applied through ACP before prompting.
    var modelOverride: String {
        get { settings.model(for: agent) }
        set {
            guard newValue != settings.model(for: agent) else { return }
            settings.setModel(newValue, for: agent)
            disconnect()
        }
    }

    func selectedModel(for definition: ACPAgentDefinition) -> String { settings.model(for: definition) }

    func selectModel(_ model: String, for definition: ACPAgentDefinition) {
        settings.setModel(model, for: definition)
        if agent.id == definition.id { disconnect() }
        if let chat = chats[key] { putAside(chat) }
        chats[key] = nil
    }

    /// A new chat for the ⌘E line: the current one is put aside as `startNewChat` does, but the agent's
    /// process is kept and the next prompt opens a session in it — a relaunch of the adapter is
    /// seconds, and the line is asked for many times an hour. Not while a turn is running: that turn
    /// is still writing to the chat, and the prompt that follows is refused as busy anyway.
    func startFreshChat() {
        guard state != .prompting else { return }
        let key = currentChatKey
        if let chat = chats[key] { putAside(chat) }
    }
        if liveChatKey == key, client != nil { needsFreshSession = true }
    }

    /// Set by `startFreshChat`: the live process is right, its session belongs to a chat put aside.
    @ObservationIgnored private var needsFreshSession = false

    private func openFreshSession(_ client: ACPClient) async throws {
        needsFreshSession = false
        guard let directory = sessionDirectory else { return }
        let session = try await client.newSession(cwd: directory, mcpServers: [MCPStdioBridge.acpServer])
        let key = chatKeyForWriting()
        sessionId = session.sessionId
        modes = session.modes
        sessionModels = AgentModels(configOptions: session.configOptions, models: session.models)
        chats[key]?.sessionID = session.sessionId
        let model = modelOverride.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty, let catalog = sessionModels, catalog.choices.contains(where: { $0.id == model }) {
            try await client.setModel(sessionId: session.sessionId, modelID: model, catalog: catalog)
        }
    }

    /// A new chat, made now rather than on its first message, so it has an id to open a window on.
    func beginChat() -> UUID {
        startNewChat()
        let chat = AgentChat(agentID: agent.id, directoryPath: workingDirectory.path)
        chats[chat.key] = chat
        return chat.id
    }

    // MARK: History

    /// Conversations put aside, newest first — summaries only; `chat(_:)` reads one whole.
    private(set) var past: [AgentChat] = []
    @ObservationIgnored let archive = AgentChatArchive()
    /// The sessions each agent keeps for a folder, whoever started them (`session/list`).
    let catalog = AgentSessionCatalog()
    /// Transcripts of past chats already read from `archive`, so a page redrawn is not a file read.
    @ObservationIgnored private var loadedPast: [UUID: AgentChat] = [:]

    /// Every conversation — the ones going on and the ones put aside — newest first.
    var history: [AgentChat] {
        (chats.values.filter { !$0.transcript.isEmpty || $0.sessionID != nil }.map(\.summary) + past)
            .sorted { ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast) }
    }

    /// One conversation, transcript and all.
    func chat(_ id: UUID) -> AgentChat? {
        if let current = chats.values.first(where: { $0.id == id }) { return current }
        guard let summary = past.first(where: { $0.id == id }) else { return nil }
        if let loaded = loadedPast[id] { return loaded }
        var chat = archive.load(id) ?? summary
        chat.title = chat.title ?? summary.title
        loadedPast[id] = chat
        return chat
    }

    /// Whether this is the conversation its agent is having in its folder now — the one a prompt
    /// to that agent there goes on with.
    func isCurrent(_ id: UUID) -> Bool { chats.values.contains { $0.id == id } }

    /// Whether this conversation's turn is running.
    func isRunning(_ id: UUID) -> Bool {
        state == .prompting && liveChatKey.flatMap { chats[$0]?.id } == id
    }

    /// Makes a conversation the current one for its agent in its folder, putting aside the one that
    /// was, and selects its agent. The next prompt resumes its session with `session/load`, which
    /// also brings the transcript back from the agent when six has none (`adopt`).
    ///
    /// The folder has to be the one the store works in — the selected profile's — because that is
    /// where the session's files are; false when it is not.
    @discardableResult
    func open(_ id: UUID) -> Bool {
        guard let chat = chat(id), chat.directoryPath == workingDirectory.path,
              let definition = definition(for: chat.agentID)
        else { return false }
        if agent != definition { agent = definition }
        guard !isCurrent(id) else { return true }
        let key = chat.key
        if liveChatKey == key { disconnect() }
        if let current = chats[key] { putAside(current) }
        past.removeAll { $0.id == id }
        loadedPast[id] = nil
        archive.remove(id)
        chats[key] = chat
        return true
    }

    /// The agent a chat was had with, while six still has it — built in or added by hand.
    func definition(for agentID: String) -> ACPAgentDefinition? {
        (ACPAgentDefinition.builtIn + settings.customAgents).first { $0.id == agentID }
    }

    /// The conversations had in the folder the agent works in now, newest first, whose title has
    /// every word of `query` — what the ⌘E line offers after a `/`.
    func chats(matching query: String, limit: Int = 5) -> [AgentChat] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let folder = workingDirectory.path
        return Array(history.lazy.filter { chat in
            chat.directoryPath == folder && words.allSatisfy { (chat.title ?? "").lowercased().contains($0) }
        }.prefix(limit))
    }

    /// Deletes a past conversation from six. The agent keeps its own copy of the session.
    func forget(_ id: UUID) {
        past.removeAll { $0.id == id }
        loadedPast[id] = nil
        archive.remove(id)
    }

    /// A session six did not know — started from the agent's own CLI, or dropped before six kept a
    /// history — taken into it. It has no transcript here yet; opening it asks the agent for one.
    @discardableResult
    func adopt(_ session: ACP.SessionInfo, agent definition: ACPAgentDefinition) -> UUID {
        if let known = history.first(where: { $0.sessionID == session.sessionId }) { return known.id }
        var chat = AgentChat(agentID: definition.id, directoryPath: session.cwd, sessionID: session.sessionId,
                             title: session.title)
        let date = session.updatedAt.flatMap { try? Date($0, strategy: .iso8601) }
        chat.createdAt = date
        chat.updatedAt = date
        past.insert(chat, at: 0)
        return chat.id
    }

    private func putAside(_ chat: AgentChat) {
        // A chat that never got a word in is not a conversation to come back to.
        guard !chat.transcript.isEmpty else { return }
        archive.save(chat)
        loadedPast[chat.id] = nil
        past.removeAll { $0.id == chat.id }
        past.insert(chat.summary, at: 0)

    private(set) var state: State = .idle
    private(set) var permissionPrompt: AgentPermissionPrompt?
    private(set) var modes: ACP.SessionModeState?
    private(set) var agentInfo: ACP.Implementation?
    private(set) var sessionId: String?

    let toolchain = AgentToolchain()
    let modelDiscovery: AgentModelDiscovery
    private var sessionModels: AgentModels?

    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var delegateBox: DelegateBox?
    @ObservationIgnored private var openMessageID: String?
    /// Whether the agent has said anything in the turn that is running. A refusal it explained in
    /// prose ("You've hit your session limit · resets 7:10pm") needs nothing added to it.
    @ObservationIgnored private var saidSomething = false
    @ObservationIgnored private var openThoughtID: String?
    @ObservationIgnored private var openUserID: String?

    var isConnected: Bool { client != nil && sessionId != nil }

    // MARK: Connection

    /// `SIX_ACP_TRACE=1` in the environment mirrors the connection steps and every JSON-RPC line to stderr.
    nonisolated static let traces = ProcessInfo.processInfo.environment["SIX_ACP_TRACE"] != nil

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard traces else { return }
        Log.debug(.acp, message())
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
            if !model.isEmpty, agent.id == ACPAgentDefinition.claudeCode.id {
                definition.environment["ANTHROPIC_MODEL"] = model
            }
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
            // A resumed conversation may remember a previously selected model. Read the agent's
            // fresh-session default before loading it so choosing Default really resets the model.
            var defaultModel: String?
            if model.isEmpty, savedSession != nil {
                let defaults = try await client.newSession(cwd: directory)
                defaultModel = AgentModels(configOptions: defaults.configOptions, models: defaults.models).current
            }
            if let savedSession, await resumeSession(savedSession, client: client, capabilities: info.agentCapabilities, cwd: directory, mcpServers: servers) {
                append(.status(String(localized: "Resumed session with \(agentName) · \(directory.path)")))
            } else {
                let session = try await client.newSession(cwd: directory, mcpServers: servers)
                sessionId = session.sessionId
                modes = session.modes
                sessionModels = AgentModels(configOptions: session.configOptions, models: session.models)
                chats[key]?.sessionID = session.sessionId
                append(.status(savedSession == nil
                    ? String(localized: "Connected to \(agentName) · \(directory.path)")
                    : String(localized: "Previous session couldn't be resumed; new session with \(agentName) · \(directory.path)")))
            }
            let requestedModel = model.isEmpty ? (defaultModel ?? "") : model
            if let sessionId, let catalog = sessionModels, !requestedModel.isEmpty {
                if !catalog.choices.isEmpty {
                    guard catalog.choices.contains(where: { $0.id == requestedModel }) else {
                        throw JSONRPCError.invalidParams(String(localized: "The selected model is no longer available. Choose another model in Assistant settings."))
                    }
                    try await client.setModel(sessionId: sessionId, modelID: requestedModel, catalog: catalog)
                } else if !model.isEmpty, agent.id != ACPAgentDefinition.claudeCode.id {
                    throw JSONRPCError.invalidParams(String(localized: "This agent does not support model selection. Choose its default model in Assistant settings."))
                }
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
            sessionModels = AgentModels(configOptions: response?.configOptions, models: response?.models)
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
        sessionModels = nil
        permissionPrompt = nil
        if !keepState { state = .idle }
    }

    // MARK: Prompting

    /// What a prompt streams back to whoever asked (the ⌘E bar mirrors it).
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
        needsFreshSession = false
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
        saidSomething = false
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
            // An error that carries no sentence of its own is a code on screen; what the CLI last
            // printed is then the only account of the refusal, and it goes with it. Not when the
            // agent has already spoken this turn — it said why in its own words, and the stderr
            // tail underneath it is the noise that made the account unreadable.
            let stderr = await client.recentStderr
        if let live = client, needsFreshSession {
            do { try await openFreshSession(live) } catch {
                Self.trace("fresh session failed: \(error)")
                disconnect()
            }
        }
            var message = error.localizedDescription
            if !saidSomething, (error as? JSONRPCError)?.detail == nil {
                let tail = stderr.split(separator: "\n", omittingEmptySubsequences: true)
                    .suffix(5).joined(separator: "\n")
                if !tail.isEmpty, !message.contains(tail) { message += "\n\(tail)" }
            }
            Self.trace("prompt failed: \(error) \(stderr)")
            append(.status(String(localized: "Error: \(message)")))
            state = .ready
            return .failed(message)
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
            saidSomething = true
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
        case .sessionInfo(let title):
            if let title, !title.isEmpty { chats[chatKeyForWriting()]?.title = title }
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
