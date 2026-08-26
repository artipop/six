import Foundation

/// Receives agent-initiated traffic: streamed session updates and permission requests.
nonisolated protocol ACPClientDelegate: AnyObject, Sendable {
    func client(_ client: ACPClient, didReceive notification: ACP.SessionNotification) async
    func client(_ client: ACPClient, requestPermission request: ACP.RequestPermissionRequest) async -> ACP.RequestPermissionOutcome
}

/// High-level ACP client: spawns the agent, performs the handshake, manages sessions and prompts,
/// and serves the client-side methods (`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`).
actor ACPClient {
    let definition: ACPAgentDefinition
    private let process: ACPAgentProcess
    private let connection: JSONRPCConnection
    private weak var delegate: (any ACPClientDelegate)?

    private(set) var agentInfo: ACP.Implementation?
    private(set) var agentCapabilities: ACP.AgentCapabilities?
    private(set) var authMethods: [ACP.AuthMethod] = []

    /// Directories the agent is allowed to read/write through `fs/*`. Defaults to each session's cwd.
    private var allowedRoots: [String: URL] = [:]

    init(definition: ACPAgentDefinition, delegate: any ACPClientDelegate) async throws {
        self.definition = definition
        self.delegate = delegate
        process = try ACPAgentProcess(definition: definition, environment: await LoginShell.environment())
        connection = process.connection
    }

    var recentStderr: String { process.recentStderr }

    /// Mirrors every JSON-RPC line to stderr (debugging).
    func enableTrace() async {
        await connection.setTrace { outgoing, line in
            FileHandle.standardError.write(Data("[acp \(outgoing ? "→" : "←")] \(line.prefix(400))\n".utf8))
        }
    }

    // MARK: Lifecycle

    /// Launches the handshake. Must be called once before anything else.
    func initialize(clientInfo: ACP.Implementation = .init(name: "six", title: "Six Browser", version: "1.0")) async throws -> ACP.InitializeResponse {
        await connection.setHandlers(
            request: { [weak self] method, params in
                guard let self else { throw JSONRPCError.connectionClosed }
                return try await self.handleRequest(method: method, params: params)
            },
            notification: { [weak self] method, params in
                await self?.handleNotification(method: method, params: params)
            }
        )
        let request = ACP.InitializeRequest(clientInfo: clientInfo)
        let result = try await connection.request("initialize", params: ACPJSON(encoding: request))
        let response: ACP.InitializeResponse = try result.decode()
        guard response.protocolVersion == ACP.protocolVersion else {
            throw JSONRPCError.internalError("Unsupported ACP protocol version \(response.protocolVersion)")
        }
        agentInfo = response.agentInfo
        agentCapabilities = response.agentCapabilities
        authMethods = response.authMethods ?? []
        return response
    }

    func authenticate(methodId: String) async throws {
        _ = try await connection.request("authenticate", params: ["methodId": .string(methodId)])
    }

    func shutdown() {
        process.terminate()
    }

    // MARK: Sessions

    func newSession(cwd: URL, mcpServers: [ACP.MCPServer] = []) async throws -> ACP.NewSessionResponse {
        let request = ACP.NewSessionRequest(cwd: cwd.path, mcpServers: mcpServers)
        let response: ACP.NewSessionResponse = try await connection.request("session/new", params: ACPJSON(encoding: request)).decode()
        allowedRoots[response.sessionId] = cwd
        return response
    }

    /// Resumes a session; the agent streams its history as `session/update`s before answering.
    func loadSession(id: String, cwd: URL, mcpServers: [ACP.MCPServer] = []) async throws -> ACP.LoadSessionResponse? {
        let request = ACP.LoadSessionRequest(sessionId: id, cwd: cwd.path, mcpServers: mcpServers)
        let result = try await connection.request("session/load", params: ACPJSON(encoding: request))
        allowedRoots[id] = cwd
        return try? result.decode()
    }

    func setMode(sessionId: String, modeId: String) async throws {
        let request = ACP.SetSessionModeRequest(sessionId: sessionId, modeId: modeId)
        _ = try await connection.request("session/set_mode", params: ACPJSON(encoding: request))
    }

    /// Sends a prompt and waits for the turn to finish. Updates stream to the delegate meanwhile.
    func prompt(sessionId: String, _ blocks: [ACP.ContentBlock]) async throws -> ACP.StopReason {
        let request = ACP.PromptRequest(sessionId: sessionId, prompt: blocks)
        let response: ACP.PromptResponse = try await connection.request("session/prompt", params: ACPJSON(encoding: request)).decode()
        return response.stopReason
    }

    func prompt(sessionId: String, text: String) async throws -> ACP.StopReason {
        try await prompt(sessionId: sessionId, [.text(text)])
    }

    func cancel(sessionId: String) async throws {
        try await connection.notify("session/cancel", params: ["sessionId": .string(sessionId)])
    }

    // MARK: Agent → client

    private func handleNotification(method: String, params: ACPJSON?) async {
        guard method == "session/update", let notification = try? ACP.SessionNotification(params: params) else { return }
        await delegate?.client(self, didReceive: notification)
    }

    private func handleRequest(method: String, params: ACPJSON?) async throws -> ACPJSON {
        switch method {
        case "session/request_permission":
            guard let params else { throw JSONRPCError.invalidParams(method) }
            let request: ACP.RequestPermissionRequest = try params.decode()
            let outcome = await delegate?.client(self, requestPermission: request) ?? .cancelled
            return outcome.json
        case "fs/read_text_file":
            guard let params else { throw JSONRPCError.invalidParams(method) }
            return try ACPJSON(encoding: try readTextFile(try params.decode()))
        case "fs/write_text_file":
            guard let params else { throw JSONRPCError.invalidParams(method) }
            try writeTextFile(try params.decode())
            return .null
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    private func readTextFile(_ request: ACP.ReadTextFileRequest) throws -> ACP.ReadTextFileResponse {
        let url = try authorizedURL(request.path, sessionId: request.sessionId)
        var text = try String(contentsOf: url, encoding: .utf8)
        if request.line != nil || request.limit != nil {
            var lines = text.components(separatedBy: "\n")
            let start = max(0, (request.line ?? 1) - 1)
            lines = Array(lines.dropFirst(start))
            if let limit = request.limit { lines = Array(lines.prefix(limit)) }
            text = lines.joined(separator: "\n")
        }
        return .init(content: text)
    }

    private func writeTextFile(_ request: ACP.WriteTextFileRequest) throws {
        let url = try authorizedURL(request.path, sessionId: request.sessionId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try request.content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func authorizedURL(_ path: String, sessionId: String) throws -> URL {
        guard path.hasPrefix("/") else { throw JSONRPCError.invalidParams("path must be absolute") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let root = allowedRoots[sessionId] else { throw JSONRPCError.invalidParams("unknown session \(sessionId)") }
        guard url.path.hasPrefix(root.standardizedFileURL.path) else {
            throw JSONRPCError(code: -32001, message: "Access outside the session directory is not allowed: \(path)")
        }
        return url
    }
}
