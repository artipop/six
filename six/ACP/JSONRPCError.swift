import Foundation

/// JSON-RPC 2.0's error object. It outlives the connection that carries it: the browser tools
/// answer in it whether they were called over ACP, over MCP, or by a language model in-process.
nonisolated struct JSONRPCError: Error, Codable, Sendable, LocalizedError {
    var code: Int
    var message: String
    var data: ACPJSON?

    var errorDescription: String? { "\(message) (\(code))" }

    static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    static func methodNotFound(_ method: String) -> JSONRPCError { .init(code: -32601, message: "Method not found: \(method)") }
    static func invalidParams(_ detail: String) -> JSONRPCError { .init(code: -32602, message: "Invalid params: \(detail)") }
    static func internalError(_ detail: String) -> JSONRPCError { .init(code: -32603, message: detail) }
    static let connectionClosed = JSONRPCError(code: -32000, message: "Connection closed")
}
