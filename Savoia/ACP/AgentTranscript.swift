import Foundation

// The transcript's own shape, kept apart from the session that fills it: it is part of the
// state file, which every platform reads and writes, while the session is a local process and
// only the Mac has one.

/// One rendered item in the agent transcript.
nonisolated struct AgentTranscriptItem: Identifiable, Sendable, Codable {
    enum Kind: Sendable {
        case user(String)
        case agent(String)
        case thought(String)
        case toolCall(ACP.ToolCall)
        case plan([ACP.PlanEntry])
        case status(String)
    }
    let id: String
    var kind: Kind

    init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    // Stored as `{id, type, text | toolCall | plan}`.
    private enum CodingKeys: String, CodingKey { case id, type, text, toolCall, plan }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        switch try c.decode(String.self, forKey: .type) {
        case "user": kind = .user(try c.decode(String.self, forKey: .text))
        case "agent": kind = .agent(try c.decode(String.self, forKey: .text))
        case "thought": kind = .thought(try c.decode(String.self, forKey: .text))
        case "toolCall": kind = .toolCall(try c.decode(ACP.ToolCall.self, forKey: .toolCall))
        case "plan": kind = .plan(try c.decode([ACP.PlanEntry].self, forKey: .plan))
        case "status": kind = .status(try c.decode(String.self, forKey: .text))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown transcript item \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch kind {
        case .user(let text): try c.encode("user", forKey: .type); try c.encode(text, forKey: .text)
        case .agent(let text): try c.encode("agent", forKey: .type); try c.encode(text, forKey: .text)
        case .thought(let text): try c.encode("thought", forKey: .type); try c.encode(text, forKey: .text)
        case .status(let text): try c.encode("status", forKey: .type); try c.encode(text, forKey: .text)
        case .toolCall(let call): try c.encode("toolCall", forKey: .type); try c.encode(call, forKey: .toolCall)
        case .plan(let entries): try c.encode("plan", forKey: .type); try c.encode(entries, forKey: .plan)
        }
    }
}
