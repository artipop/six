import Foundation

/// six as an MCP **host**: one connection to one server, with the MCP Apps extension declared.
///
/// Small on purpose. It answers what a host needs to show an app — what tools are there, which of
/// them carry an interface, the HTML behind one, and the result of calling one — and nothing else.
/// The parts that decide *whether* to call a tool live above it: the agent panel, the permission
/// bar, and (later) `MCPAppHost`, which proxies an app's own requests back down here.
actor MCPClient {
    struct ServerInfo: Sendable {
        var name: String
        var title: String?
        var version: String?
        var protocolVersion: String
        /// Whether the server acknowledged `io.modelcontextprotocol/ui` in its own capabilities.
        /// Servers are not required to echo it, so a `false` here proves nothing on its own.
        var acknowledgedUIExtension: Bool
        var instructions: String?
    }

    enum Failure: LocalizedError {
        case notConnected
        case noSuchResource(String)
        case notAnApp(uri: String, mimeType: String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the MCP server."
            case .noSuchResource(let uri): "The server returned no contents for \(uri)."
            case .notAnApp(let uri, let mimeType): "\(uri) is \(mimeType), not \(MCPApps.mimeType)."
            case .server(let message): message
            }
        }
    }

    let definition: MCPServerDefinition
    /// Signing in to a remote server, when it asks. Nil for a stdio server, which never does.
    private let authorization: MCPAuthorization?
    /// How long one HTTP request may take. Short when six is only looking around (a sweep, a probe),
    /// long when somebody is waiting on a tool that does real work.
    private let timeout: TimeInterval
    private var transport: (any MCPTransport)?
    private(set) var info: ServerInfo?
    /// Tools as of the last `listTools()`, kept so an app's `tools/call` can be checked against the
    /// declared visibility without another round trip.
    private(set) var tools: [MCPTool] = []

    init(definition: MCPServerDefinition, authorization: MCPAuthorization? = nil, timeout: TimeInterval = 120) {
        self.definition = definition
        self.authorization = definition.isRemote ? authorization : nil
        self.timeout = timeout
    }

    var isConnected: Bool { info != nil && (transport?.isRunning ?? false) }
    /// Whatever the far end had to say when it failed: a process's stderr, an HTTP status.
    var recentStderr: String { transport?.diagnostics ?? "" }

    // MARK: Lifecycle

    /// Launches the server, performs the handshake, and returns what it said about itself.
    @discardableResult
    func connect() async throws -> ServerInfo {
        if let info { return info }
        if transport == nil {
            if let url = definition.url {
                let server = definition
                let tokens = authorization.map { authorization in
                    MCPHTTPTransport.Tokens(
                        current: { await authorization.token(for: server) },
                        renew: { challenge in await authorization.authorize(server, challenge: challenge) }
                    )
                }
                transport = MCPHTTPTransport(url: url, headers: definition.headers, tokens: tokens, timeout: timeout)
            } else {
                transport = try MCPStdioTransport(definition: definition,
                                                  environment: await LoginShell.environment(),
                                                  trace: MCPClient.isTracing)
            }
        }
        return try await handshake()
    }

    /// `initialize`, the version check, and the notification that follows.
    ///
    /// Separate from `connect` because it is run twice: once when the connection is made, and again
    /// if the server forgets the session underneath it. Goes straight to the transport rather than
    /// through `request`, which is what would call this — a handshake that re-handshakes has no
    /// bottom.
    @discardableResult
    private func handshake() async throws -> ServerInfo {
        guard let transport else { throw Failure.notConnected }
        info = nil
        let result: ACPJSON
        do {
            result = try await transport.request("initialize", params: [
                "protocolVersion": .string(MCPApps.supportedProtocolVersions[0]),
                "capabilities": [
                    "extensions": .object([
                        MCPApps.extensionID: ["mimeTypes": [.string(MCPApps.mimeType)]],
                    ]),
                ],
                "clientInfo": MCPApps.clientInfo,
            ])
        } catch let error as JSONRPCError {
            throw Failure.server(error.message)
        }
        let negotiated = result["protocolVersion"]?.stringValue ?? ""
        // A version six does not speak is a conversation that goes wrong later rather than here.
        // Saying so now, by name, beats a `tools/list` that comes back shaped differently.
        guard MCPApps.supportedProtocolVersions.contains(negotiated) else {
            await transport.close()
            self.transport = nil
            throw Failure.server("\(definition.name) speaks MCP \(negotiated.isEmpty ? "an unnamed version" : negotiated), which six does not.")
        }
        let server = result["serverInfo"]
        let info = ServerInfo(
            name: server?["name"]?.stringValue ?? definition.name,
            title: server?["title"]?.stringValue,
            version: server?["version"]?.stringValue,
            protocolVersion: negotiated,
            acknowledgedUIExtension: result["capabilities"]?["extensions"]?[MCPApps.extensionID] != nil,
            instructions: result["instructions"]?.stringValue
        )
        self.info = info
        try? await transport.notify("notifications/initialized", params: nil)
        return info
    }

    /// Closing from the main actor, where there is nothing to await on: a server being dropped is
    /// not something anyone waits for.
    nonisolated func closeDetached() {
        Task { await close() }
    }

    func close() async {
        await transport?.close()
        transport = nil
        info = nil
        tools = []
    }

    // MARK: Tools and resources

    @discardableResult
    func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list")
        tools = (result["tools"]?.arrayValue ?? []).map(MCPTool.init(json:))
        return tools
    }

    /// The tools an agent may see: everything the server did not mark app-only.
    var modelTools: [MCPTool] { tools.filter { $0.visibility.contains(.model) } }

    func tool(named name: String) -> MCPTool? { tools.first { $0.name == name } }

    /// A `resources/read`, answered as the server wrote it — what an app's own read is proxied to.
    func readResource(_ uri: String) async throws -> ACPJSON {
        try await request("resources/read", params: ["uri": .string(uri)])
    }

    /// Reads a `ui://` resource and parses the extension's metadata out of it.
    func readUIResource(_ uri: String) async throws -> MCPUIResource {
        let result = try await request("resources/read", params: ["uri": .string(uri)])
        let contents = result["contents"]?.arrayValue ?? []
        guard let resource = contents.lazy.compactMap(MCPUIResource.init(contents:))
            .first(where: { $0.uri == uri }) ?? contents.lazy.compactMap(MCPUIResource.init(contents:)).first
        else { throw Failure.noSuchResource(uri) }
        guard resource.isApp else { throw Failure.notAnApp(uri: uri, mimeType: resource.mimeType) }
        return resource
    }

    /// Calls a tool. The raw `CallToolResult` comes back untouched: an app is handed it verbatim as
    /// `ui/notifications/tool-result`, and the agent needs its `content` as the server wrote it.
    func callTool(_ name: String, arguments: ACPJSON = [:]) async throws -> ACPJSON {
        try await request("tools/call", params: ["name": .string(name), "arguments": arguments])
    }

    func ping() async throws {
        _ = try await request("ping")
    }

    // MARK: Plumbing

    private func request(_ method: String, params: ACPJSON? = nil) async throws -> ACPJSON {
        guard let transport else { throw Failure.notConnected }
        do {
            return try await transport.request(method, params: params)
        } catch is MCPHTTPTransport.SessionExpired {
            // The server dropped the session — restarted, or timed it out. Shake hands again on the
            // same connection and ask once more; the caller never sees it happen.
            try await handshake()
            do {
                return try await transport.request(method, params: params)
            } catch let error as JSONRPCError {
                throw Failure.server(error.message)
            }
        } catch let error as JSONRPCError {
            throw Failure.server(error.message)
        }
    }

    /// `SIX_MCP_TRACE=1` mirrors every line of every server connection to stderr, the way
    /// `SIX_ACP_TRACE` does for the agent.
    static var isTracing: Bool { ProcessInfo.processInfo.environment["SIX_MCP_TRACE"] != nil }
}
