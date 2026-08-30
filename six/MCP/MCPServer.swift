import Foundation
import Observation

/// The browser as an MCP server (https://modelcontextprotocol.io): `initialize`, `tools/list`,
/// `tools/call`, `ping`, over the shared `BrowserToolCatalog`.
@MainActor
final class MCPServer {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverInfo: ACPJSON = ["name": "six", "title": "Six Browser", "version": "1.0"]

    let catalog: BrowserToolCatalog
    /// The servers six is itself a host to. Their tools are passed on to the agent under six's own
    /// name, so a call to one goes through here — which is how six gets to see that the tool carries
    /// an interface and open a window for it. See [mcp-apps.md](../../docs/mcp-apps.md).
    weak var apps: MCPAppStore?

    init(catalog: BrowserToolCatalog) {
        self.catalog = catalog
    }

    var toolNames: [String] { catalog.tools(for: .mcp).map(\.name) }

    func handle(method: String, params: ACPJSON?) async throws -> ACPJSON {
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": Self.serverInfo,
                "instructions": .string(BrowserToolCatalog.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            let own = catalog.tools(for: .mcp).map(\.mcpDescriptor)
            return ["tools": .array(own + (await apps?.agentTools() ?? []))]
        case "tools/call":
            guard let name = params?["name"]?.stringValue else { throw JSONRPCError.invalidParams("name") }
            let arguments = params?["arguments"] ?? [:]
            // A shared server's tool first: six's own names carry no server prefix, so the two sets
            // cannot collide, and answering here is what puts the window on screen.
            if let answer = await apps?.callForAgent(name, arguments: arguments) { return answer }
            guard let tool = catalog.tool(named: name), tool.surfaces.contains(.mcp) else {
                throw JSONRPCError.invalidParams("Unknown tool \(name)")
            }
            do {
                return Self.result(try await tool.run(arguments))
            } catch let error as BrowserTool.Failure {
                return Self.result(error.message, isError: true)
            } catch {
                return Self.result(error.localizedDescription, isError: true)
            }
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    /// Notifications (`notifications/initialized`, `notifications/cancelled`) need no reply.
    func handle(notification method: String, params: ACPJSON?) {}

    private static func result(_ text: String, isError: Bool = false) -> ACPJSON {
        var object: [String: ACPJSON] = ["content": [["type": "text", "text": .string(text)]]]
        if isError { object["isError"] = true }
        return .object(object)
    }
}

/// Owns the socket listener and one `JSONRPCConnection` per MCP client, routing requests to `MCPServer`.
@MainActor
@Observable
final class MCPHost {
    @ObservationIgnored let server: MCPServer
    @ObservationIgnored private let listener = MCPSocketListener()
    @ObservationIgnored private var connections: [ObjectIdentifier: JSONRPCConnection] = [:]
    private(set) var status: String

    var socketPath: String { listener.path }

    init(server: MCPServer) {
        self.server = server
        status = String(localized: "not started")
    }

    func start() {
        do {
            try listener.start { [weak self] handle in
                Task { @MainActor [weak self] in self?.attach(handle) }
            }
            status = String(localized: "listening at \(listener.path)")
        } catch {
            status = error.localizedDescription
        }
    }

    private func attach(_ handle: FileHandle) {
        let connection = JSONRPCConnection(input: handle, output: handle)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        let server = self.server
        let detach: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.connections[key] = nil }
        }
        Task {
            await connection.setHandlers(
                request: { method, params in try await server.handle(method: method, params: params) },
                notification: { method, params in await server.handle(notification: method, params: params) }
            )
            await connection.setOnClose(detach)
            await connection.start()
        }
    }
}
