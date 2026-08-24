import Foundation

/// Error returned by the peer, or raised when the transport fails.
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

/// A JSON-RPC 2.0 peer over newline-delimited JSON — the ACP transport.
///
/// Owns the outgoing request ids and the pending continuations; delivers incoming requests and
/// notifications to the handlers you install. Both sides can initiate requests (ACP needs that for
/// `session/request_permission` and `fs/*`).
actor JSONRPCConnection {
    typealias RequestHandler = @Sendable (_ method: String, _ params: ACPJSON?) async throws -> ACPJSON
    typealias NotificationHandler = @Sendable (_ method: String, _ params: ACPJSON?) async -> Void

    private let output: FileHandle
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ACPJSON, Error>] = [:]
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var readerTask: Task<Void, Never>?
    private(set) var isClosed = false

    /// Optional tap of every raw line in both directions, for debugging.
    var trace: (@Sendable (_ outgoing: Bool, _ line: String) -> Void)?

    init(input: FileHandle, output: FileHandle) {
        self.output = output
        self.input = input
    }

    private let input: FileHandle

    /// Starts reading the peer's output. Call once after construction.
    func start() {
        guard readerTask == nil else { return }
        let input = self.input
        readerTask = Task { [weak self] in
            do {
                for try await line in input.bytes.lines {
                    guard let self else { return }
                    await self.receive(line: line)
                }
            } catch {}
            await self?.close()
        }
    }

    func setHandlers(request: RequestHandler?, notification: NotificationHandler?) {
        requestHandler = request
        notificationHandler = notification
    }

    func setTrace(_ trace: (@Sendable (_ outgoing: Bool, _ line: String) -> Void)?) {
        self.trace = trace
    }

    // MARK: Outgoing

    func request(_ method: String, params: ACPJSON? = nil) async throws -> ACPJSON {
        guard !isClosed else { throw JSONRPCError.connectionClosed }
        let id = nextID
        nextID += 1
        var envelope: [String: ACPJSON] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { envelope["params"] = params }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(.object(envelope))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, params: ACPJSON? = nil) throws {
        var envelope: [String: ACPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { envelope["params"] = params }
        try write(.object(envelope))
    }

    private func respond(id: ACPJSON, result: ACPJSON) throws {
        try write(.object(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func respond(id: ACPJSON, error: JSONRPCError) throws {
        try write(.object(["jsonrpc": "2.0", "id": id, "error": try ACPJSON(encoding: error)]))
    }

    private func write(_ value: ACPJSON) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        trace?(true, String(decoding: data.dropLast(), as: UTF8.self))
        try output.write(contentsOf: data)
    }

    // MARK: Incoming

    private func receive(line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        trace?(false, trimmed)
        guard let message = try? JSONDecoder().decode(ACPJSON.self, from: Data(trimmed.utf8)),
              let object = message.objectValue else { return }

        if let method = object["method"]?.stringValue {
            let params = object["params"]
            if let id = object["id"], !id.isNull {
                // Request from the peer.
                let handler = requestHandler
                Task {
                    do {
                        guard let handler else { throw JSONRPCError.methodNotFound(method) }
                        let result = try await handler(method, params)
                        try await self.respond(id: id, result: result)
                    } catch let error as JSONRPCError {
                        try? await self.respond(id: id, error: error)
                    } catch {
                        try? await self.respond(id: id, error: .internalError(error.localizedDescription))
                    }
                }
            } else {
                let handler = notificationHandler
                Task { await handler?(method, params) }
            }
        } else if let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"], let rpcError = try? error.decode(JSONRPCError.self) {
                continuation.resume(throwing: rpcError)
            } else {
                continuation.resume(returning: object["result"] ?? .null)
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readerTask?.cancel()
        for (_, continuation) in pending { continuation.resume(throwing: JSONRPCError.connectionClosed) }
        pending.removeAll()
    }
}
