import Foundation

/// JSON-RPC 2.0's error object. It outlives the connection that carries it: the browser tools
/// answer in it whether they were called over ACP, over MCP, or by a language model in-process.
nonisolated struct JSONRPCError: Error, Codable, Sendable, LocalizedError {
    var code: Int
    var message: String
    var data: ACPJSON?

    /// What a person reads when a call fails. The `message` half of a JSON-RPC error is often a
    /// placeholder — the ACP adapters wrap whatever the CLI said in an internal error and put the
    /// sentence a person can act on in `data` — so the readable half comes first and the number
    /// only when nothing else says anything. Codex answers a spent subscription that way: a code on
    /// screen, while the text about the usage limit and where to buy more sat in `data`.
    var errorDescription: String? {
        let headline = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detail = Self.readable(data) else {
            return headline.isEmpty ? "Error \(code)" : "\(headline) (\(code))"
        }
        guard !headline.isEmpty, !Self.isPlaceholder(headline),
              !detail.localizedCaseInsensitiveContains(headline) else { return detail }
        return "\(headline): \(detail)"
    }

    /// The readable half, when the peer sent one — nil when the error is a code and a placeholder,
    /// which is when whatever the process said on stderr is the only account of what happened.
    var detail: String? { Self.readable(data) }

    /// The sentence out of JSON-RPC's free-form `data`. Where it sits is a matter of taste per
    /// agent: a bare string, `details` for the Rust ACP crate the Codex adapter is built on, and
    /// `message` / `error` / `description` / `reason` for the rest.
    private static func readable(_ data: ACPJSON?) -> String? {
        switch data {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let fields):
            for key in ["details", "message", "error", "description", "reason"] {
                if let text = readable(fields[key]) { return text }
            }
            return nil
        default:
            return nil
        }
    }

    /// A headline that names the transport rather than the trouble, and so adds nothing in front of
    /// a sentence that names the trouble.
    private static func isPlaceholder(_ headline: String) -> Bool {
        let stripped = headline.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:! "))
        return ["error", "internal error", "internal", "request failed", "failed", "unknown error"].contains(stripped)
    }

    static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    static func methodNotFound(_ method: String) -> JSONRPCError { .init(code: -32601, message: "Method not found: \(method)") }
    static func invalidParams(_ detail: String) -> JSONRPCError { .init(code: -32602, message: "Invalid params: \(detail)") }
    static func internalError(_ detail: String) -> JSONRPCError { .init(code: -32603, message: detail) }
    static let connectionClosed = JSONRPCError(code: -32000, message: "Connection closed")
}
