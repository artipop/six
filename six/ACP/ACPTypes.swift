import Foundation

// Agent Client Protocol (https://agentclientprotocol.com) wire types, protocol version 1.
// Property keys are camelCase; discriminator values are snake_case.

nonisolated enum ACP {
    static let protocolVersion = 1

    // MARK: initialize

    struct ClientCapabilities: Codable, Sendable {
        struct FileSystem: Codable, Sendable {
            var readTextFile = true
            var writeTextFile = true
        }
        var fs = FileSystem()
        var terminal = false
    }

    struct Implementation: Codable, Sendable {
        var name: String
        var title: String?
        var version: String
    }

    struct InitializeRequest: Codable, Sendable {
        var protocolVersion = ACP.protocolVersion
        var clientCapabilities = ClientCapabilities()
        var clientInfo: Implementation?
    }

    struct AgentCapabilities: Codable, Sendable {
        struct PromptCapabilities: Codable, Sendable {
            var image: Bool?
            var audio: Bool?
            var embeddedContext: Bool?
        }
        var loadSession: Bool?
        var promptCapabilities: PromptCapabilities?
        var mcpCapabilities: ACPJSON?
    }

    struct AuthMethod: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var description: String?
    }

    struct InitializeResponse: Codable, Sendable {
        var protocolVersion: Int
        var agentCapabilities: AgentCapabilities?
        var agentInfo: Implementation?
        var authMethods: [AuthMethod]?
    }

    // MARK: session/new, session/load, session/set_mode

    struct MCPServer: Codable, Sendable {
        struct EnvVariable: Codable, Sendable {
            var name: String
            var value: String
        }
        var name: String
        var command: String
        var args: [String] = []
        var env: [EnvVariable] = []
    }

    struct NewSessionRequest: Codable, Sendable {
        var cwd: String
        var mcpServers: [MCPServer] = []
    }

    struct SessionMode: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var name: String
        var description: String?
    }

    struct SessionModeState: Codable, Sendable {
        var currentModeId: String
        var availableModes: [SessionMode]
    }

    struct NewSessionResponse: Codable, Sendable {
        var sessionId: String
        var modes: SessionModeState?
    }

    struct LoadSessionRequest: Codable, Sendable {
        var sessionId: String
        var cwd: String
        var mcpServers: [MCPServer] = []
    }

    struct SetSessionModeRequest: Codable, Sendable {
        var sessionId: String
        var modeId: String
    }

    // MARK: Content

    enum ContentBlock: Codable, Sendable, Equatable {
        case text(String)
        case image(data: String, mimeType: String, uri: String?)
        case audio(data: String, mimeType: String)
        case resourceLink(uri: String, name: String, mimeType: String?, title: String?)
        case resource(uri: String, text: String?, mimeType: String?)

        private enum CodingKeys: String, CodingKey { case type, text, data, mimeType, uri, name, title, resource }
        private enum ResourceKeys: String, CodingKey { case uri, text, mimeType }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "text":
                self = .text(try c.decode(String.self, forKey: .text))
            case "image":
                self = .image(data: try c.decode(String.self, forKey: .data),
                              mimeType: try c.decode(String.self, forKey: .mimeType),
                              uri: try c.decodeIfPresent(String.self, forKey: .uri))
            case "audio":
                self = .audio(data: try c.decode(String.self, forKey: .data), mimeType: try c.decode(String.self, forKey: .mimeType))
            case "resource_link":
                self = .resourceLink(uri: try c.decode(String.self, forKey: .uri),
                                     name: try c.decode(String.self, forKey: .name),
                                     mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType),
                                     title: try c.decodeIfPresent(String.self, forKey: .title))
            case "resource":
                let r = try c.nestedContainer(keyedBy: ResourceKeys.self, forKey: .resource)
                self = .resource(uri: try r.decode(String.self, forKey: .uri),
                                 text: try r.decodeIfPresent(String.self, forKey: .text),
                                 mimeType: try r.decodeIfPresent(String.self, forKey: .mimeType))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown content type \(other)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type); try c.encode(text, forKey: .text)
            case .image(let data, let mimeType, let uri):
                try c.encode("image", forKey: .type); try c.encode(data, forKey: .data)
                try c.encode(mimeType, forKey: .mimeType); try c.encodeIfPresent(uri, forKey: .uri)
            case .audio(let data, let mimeType):
                try c.encode("audio", forKey: .type); try c.encode(data, forKey: .data); try c.encode(mimeType, forKey: .mimeType)
            case .resourceLink(let uri, let name, let mimeType, let title):
                try c.encode("resource_link", forKey: .type); try c.encode(uri, forKey: .uri); try c.encode(name, forKey: .name)
                try c.encodeIfPresent(mimeType, forKey: .mimeType); try c.encodeIfPresent(title, forKey: .title)
            case .resource(let uri, let text, let mimeType):
                try c.encode("resource", forKey: .type)
                var r = c.nestedContainer(keyedBy: ResourceKeys.self, forKey: .resource)
                try r.encode(uri, forKey: .uri); try r.encodeIfPresent(text, forKey: .text); try r.encodeIfPresent(mimeType, forKey: .mimeType)
            }
        }

        var plainText: String? {
            switch self {
            case .text(let t): t
            case .resource(_, let text, _): text
            case .resourceLink(let uri, let name, _, _): "\(name) <\(uri)>"
            default: nil
            }
        }
    }

    // MARK: session/prompt

    struct PromptRequest: Codable, Sendable {
        var sessionId: String
        var prompt: [ContentBlock]
    }

    enum StopReason: String, Codable, Sendable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled
    }

    struct PromptResponse: Codable, Sendable {
        var stopReason: StopReason
    }

    struct CancelNotification: Codable, Sendable {
        var sessionId: String
    }

    // MARK: Tool calls

    enum ToolKind: String, Codable, Sendable {
        case read, edit, delete, move, search, execute, think, fetch, other
    }

    enum ToolCallStatus: String, Codable, Sendable {
        case pending, inProgress = "in_progress", completed, failed
    }

    struct ToolCallLocation: Codable, Sendable, Equatable {
        var path: String
        var line: Int?
    }

    enum ToolCallContent: Codable, Sendable, Equatable {
        case content(ContentBlock)
        case diff(path: String, oldText: String?, newText: String)
        case terminal(terminalId: String)

        private enum CodingKeys: String, CodingKey { case type, content, path, oldText, newText, terminalId }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "content": self = .content(try c.decode(ContentBlock.self, forKey: .content))
            case "diff":
                self = .diff(path: try c.decode(String.self, forKey: .path),
                             oldText: try c.decodeIfPresent(String.self, forKey: .oldText),
                             newText: try c.decode(String.self, forKey: .newText))
            case "terminal": self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown tool content \(other)")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .content(let block): try c.encode("content", forKey: .type); try c.encode(block, forKey: .content)
            case .diff(let path, let old, let new):
                try c.encode("diff", forKey: .type); try c.encode(path, forKey: .path)
                try c.encodeIfPresent(old, forKey: .oldText); try c.encode(new, forKey: .newText)
            case .terminal(let id): try c.encode("terminal", forKey: .type); try c.encode(id, forKey: .terminalId)
            }
        }
    }

    /// `tool_call` (all fields) and `tool_call_update` (everything but the id optional) share this shape.
    struct ToolCall: Codable, Sendable, Identifiable {
        var toolCallId: String
        var title: String?
        var kind: ToolKind?
        var status: ToolCallStatus?
        var content: [ToolCallContent]?
        var locations: [ToolCallLocation]?
        var rawInput: ACPJSON?
        var rawOutput: ACPJSON?

        var id: String { toolCallId }
    }

    // MARK: Plan & commands

    struct PlanEntry: Codable, Sendable, Equatable {
        enum Priority: String, Codable, Sendable { case high, medium, low }
        enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", completed }
        var content: String
        var priority: Priority
        var status: Status
    }

    struct AvailableCommand: Codable, Sendable, Identifiable {
        var name: String
        var description: String
        var input: ACPJSON?
        var id: String { name }
    }

    // MARK: session/update

    enum SessionUpdate: Sendable {
        case userMessageChunk(ContentBlock)
        case agentMessageChunk(ContentBlock)
        case agentThoughtChunk(ContentBlock)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCall)
        case plan([PlanEntry])
        case availableCommandsUpdate([AvailableCommand])
        case currentModeUpdate(modeId: String)
        case unknown(kind: String, raw: ACPJSON)

        init(json: ACPJSON) throws {
            let kind = json["sessionUpdate"]?.stringValue ?? ""
            switch kind {
            case "user_message_chunk": self = .userMessageChunk(try Self.content(of: json))
            case "agent_message_chunk": self = .agentMessageChunk(try Self.content(of: json))
            case "agent_thought_chunk": self = .agentThoughtChunk(try Self.content(of: json))
            case "tool_call": self = .toolCall(try json.decode())
            case "tool_call_update": self = .toolCallUpdate(try json.decode())
            case "plan": self = .plan(try (json["entries"] ?? .array([])).decode())
            case "available_commands_update":
                self = .availableCommandsUpdate(try (json["availableCommands"] ?? .array([])).decode())
            case "current_mode_update":
                self = .currentModeUpdate(modeId: json["currentModeId"]?.stringValue ?? json["modeId"]?.stringValue ?? "")
            default: self = .unknown(kind: kind, raw: json)
            }
        }

        private static func content(of json: ACPJSON) throws -> ContentBlock {
            guard let content = json["content"] else { throw JSONRPCError.invalidParams("missing content") }
            return try content.decode()
        }
    }

    struct SessionNotification: Sendable {
        var sessionId: String
        var update: SessionUpdate

        init(params: ACPJSON?) throws {
            guard let params, let sessionId = params["sessionId"]?.stringValue, let update = params["update"] else {
                throw JSONRPCError.invalidParams("session/update")
            }
            self.sessionId = sessionId
            self.update = try SessionUpdate(json: update)
        }
    }

    // MARK: session/request_permission

    enum PermissionOptionKind: String, Codable, Sendable {
        case allowOnce = "allow_once", allowAlways = "allow_always", rejectOnce = "reject_once", rejectAlways = "reject_always"
    }

    struct PermissionOption: Codable, Sendable, Identifiable {
        var optionId: String
        var name: String
        var kind: PermissionOptionKind
        var id: String { optionId }
    }

    struct RequestPermissionRequest: Codable, Sendable {
        var sessionId: String
        var toolCall: ToolCall
        var options: [PermissionOption]
    }

    enum RequestPermissionOutcome: Sendable {
        case selected(optionId: String)
        case cancelled

        var json: ACPJSON {
            switch self {
            case .selected(let id): ["outcome": ["outcome": "selected", "optionId": .string(id)]]
            case .cancelled: ["outcome": ["outcome": "cancelled"]]
            }
        }
    }

    // MARK: fs/*

    struct ReadTextFileRequest: Codable, Sendable {
        var sessionId: String
        var path: String
        var line: Int?
        var limit: Int?
    }

    struct ReadTextFileResponse: Codable, Sendable {
        var content: String
    }

    struct WriteTextFileRequest: Codable, Sendable {
        var sessionId: String
        var path: String
        var content: String
    }
}
