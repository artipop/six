import Foundation

/// How six reaches a server. Two ways, one shape.
///
/// A local server is a process on the end of two pipes; a remote one is an HTTP endpoint. Nothing
/// above this cares which — `MCPClient` asks for a method and gets an answer, and the difference
/// between "launched it with npx" and "posted to somebody's server" stays here.
nonisolated protocol MCPTransport: AnyObject, Sendable {
    func request(_ method: String, params: ACPJSON?) async throws -> ACPJSON
    func notify(_ method: String, params: ACPJSON?) async throws
    /// Async because closing is a message too: an HTTP session is ended by a request, and a request
    /// fired at a process that is about to exit is a request nobody sends.
    func close() async
    /// Whether the far end is still there. HTTP has no such thing between calls, and says so.
    var isRunning: Bool { get }
    /// Whatever the transport can say when a connection fails — a server's stderr, an HTTP status.
    var diagnostics: String { get }
}

#if os(macOS)
/// A server as a subprocess: newline-delimited JSON-RPC over its stdio.
nonisolated final class MCPStdioTransport: MCPTransport {
    private let process: MCPServerProcess

    init(definition: MCPServerDefinition, environment: [String: String], trace: Bool) throws {
        process = try MCPServerProcess(definition: definition, environment: environment)
        if trace {
            Task { [connection = process.connection] in
                await connection.setTrace { outgoing, line in
                    Log.debug(.mcp, "\(outgoing ? "→" : "←") \(line)")
                }
            }
        }
        // Requests from a server (sampling, elicitation, roots) are not answered yet; refusing them
        // by name is better than leaving the server waiting on a reply that never comes.
        Task { [connection = process.connection] in
            await connection.setHandlers(request: { method, _ in
                throw JSONRPCError.methodNotFound(method)
            }, notification: { _, _ in })
        }
    }

    func request(_ method: String, params: ACPJSON?) async throws -> ACPJSON {
        try await process.connection.request(method, params: params)
    }

    func notify(_ method: String, params: ACPJSON?) async throws {
        try await process.connection.notify(method, params: params)
    }

    func close() async { process.terminate() }
    var isRunning: Bool { process.isRunning }
    var diagnostics: String { process.recentStderr }
}
#endif

/// A remote server over [Streamable HTTP](https://modelcontextprotocol.io/specification): every
/// request is a POST, and the answer comes back either as one JSON object or as an event stream
/// carrying it.
///
/// Two headers make it a session rather than a series of strangers: `Mcp-Session-Id`, which the
/// server hands out on `initialize` and expects back on everything after, and
/// `MCP-Protocol-Version`, which the spec requires once a version has been agreed.
///
/// Authorization, when the server asks for it, is OAuth 2.1 and lives in `MCPOAuth`: a `401` with a
/// `WWW-Authenticate` header is handed to `renew`, and the request is tried once more with whatever
/// comes back. Only here — a stdio server is a process six launched, and its credentials came with
/// its environment.
///
/// There is no long-lived GET stream here. That channel exists for a server that wants to speak
/// first — sampling, elicitation, `listChanged` — and six answers none of those yet; opening a
/// socket to ignore what arrives on it would be worse than not opening it.
nonisolated final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let extraHeaders: [String: String]
    private let tokens: Tokens?
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1
    private var lastFailure = ""

    /// Where a bearer token comes from, and how to get a new one when the server refuses this one.
    /// Nil for a server that wants no authorization at all.
    struct Tokens: Sendable {
        var current: @Sendable () async -> String?
        var renew: @Sendable (_ challenge: String?) async -> String?
    }

    /// `timeout` bounds a single request — *both* halves of it. `timeoutIntervalForResource`
    /// defaults to seven days, which is not a timeout, and a host that accepts the connection and
    /// then says nothing is exactly the case where that shows: racing the call against a sleep does
    /// not help, because the group still waits for the task it cancelled. The bound has to be in the
    /// session, so URLSession is the one that gives up.
    init(url: URL, headers: [String: String], tokens: Tokens? = nil, timeout: TimeInterval = 120) {
        self.url = url
        extraHeaders = headers
        self.tokens = tokens
        let configuration = URLSessionConfiguration.ephemeral
        // A tool call can be a slow one — a server that renders, fetches or thinks. The default 60
        // seconds is a browser's patience for a page, not an agent's for a tool.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func request(_ method: String, params: ACPJSON?) async throws -> ACPJSON {
        let id = lock.withLock { defer { nextID += 1 }; return nextID }
        var envelope: [String: ACPJSON] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { envelope["params"] = params }
        let messages = try await post(.object(envelope), expectsAnswer: true)
        guard let answer = messages.first(where: { $0["id"]?.intValue == id }) else {
            throw JSONRPCError(code: -32000, message: "\(method): the server answered nothing")
        }
        if let error = answer["error"] {
            throw JSONRPCError(code: error["code"]?.intValue ?? -32000,
                               message: error["message"]?.stringValue ?? "Server error")
        }
        return answer["result"] ?? [:]
    }

    func notify(_ method: String, params: ACPJSON?) async throws {
        var envelope: [String: ACPJSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { envelope["params"] = params }
        _ = try await post(.object(envelope), expectsAnswer: false)
    }

    /// A session six no longer needs is ended rather than left to time out — the spec asks clients
    /// to say so, and a server holding state for a window that closed an hour ago is holding it for
    /// nobody. Sent and not waited on: the answer changes nothing here.
    func close() async {
        let ending = lock.withLock { () -> String? in
            defer { sessionID = nil }
            return sessionID
        }
        if let ending {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(ending, forHTTPHeaderField: "Mcp-Session-Id")
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            request.timeoutInterval = 5
            // Awaited so it actually leaves, and ignored either way: a server that does not allow
            // clients to end sessions answers 405, which is an answer, not a problem.
            _ = try? await session.data(for: request)
        }
        session.invalidateAndCancel()
    }

    /// Between calls there is nothing to be running. Saying `true` is the honest answer for a
    /// transport that is a URL: it is as alive as the network is.
    var isRunning: Bool { true }
    var diagnostics: String { lock.withLock { lastFailure } }

    // MARK: The POST

    /// The server forgot this session. The spec is explicit about what a client does next — start a
    /// new one with a fresh `initialize` and no session id — so this is thrown for `MCPClient` to
    /// shake hands again on the same transport.
    struct SessionExpired: Error {}

    private func post(_ message: ACPJSON, expectsAnswer: Bool) async throws -> [ACPJSON] {
        do {
            return try await send(message, expectsAnswer: expectsAnswer, token: await tokens?.current())
        } catch let unauthorized as Unauthorized {
            // Once. A second 401 with a token six just went and got is the server saying no, not
            // the token being stale, and asking the person to sign in again would be a loop.
            guard let token = await tokens?.renew(unauthorized.challenge) else {
                throw JSONRPCError(code: -32000, message: "\(url.host() ?? url.absoluteString) requires authorization")
            }
            return try await send(message, expectsAnswer: expectsAnswer, token: token)
        }
    }

    /// A `401`, carrying whatever the server said about where to get a token.
    private struct Unauthorized: Error { var challenge: String? }

    private func send(_ message: ACPJSON, expectsAnswer: Bool, token: String?) async throws -> [ACPJSON] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (storedSession, storedVersion) = lock.withLock { (sessionID, protocolVersion) }
        if let storedSession { request.setValue(storedSession, forHTTPHeaderField: "Mcp-Session-Id") }
        if let storedVersion { request.setValue(storedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // A header the user typed wins: somebody who pasted an API key meant it.
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(message)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            lock.withLock { lastFailure = error.localizedDescription }
            throw JSONRPCError(code: -32000, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JSONRPCError(code: -32000, message: "Not an HTTP response")
        }
        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.withLock { sessionID = issued }
        }
        if http.statusCode == 401, tokens != nil {
            throw Unauthorized(challenge: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        // 404 to a request carrying a session id means the session is gone, not that the endpoint
        // is. The id is dropped here so the handshake that follows goes out without one.
        if http.statusCode == 404, storedSession != nil {
            lock.withLock { sessionID = nil }
            throw SessionExpired()
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(400), as: UTF8.self)
            lock.withLock { lastFailure = "HTTP \(http.statusCode): \(body)" }
            throw JSONRPCError(code: -32000, message: "HTTP \(http.statusCode) from \(url.host() ?? url.absoluteString)")
        }
        // A notification is answered with 202 and no body, which is not a failure to parse.
        guard expectsAnswer, !data.isEmpty else { return [] }

        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let messages = type.contains("text/event-stream") ? Self.eventStream(data) : Self.single(data)
        // The version is agreed on the first answer and sent with every request after it.
        if let negotiated = messages.first?["result"]?["protocolVersion"]?.stringValue {
            lock.withLock { if protocolVersion == nil { protocolVersion = negotiated } }
        }
        return messages
    }

    private static func single(_ data: Data) -> [ACPJSON] {
        guard let value = try? JSONDecoder().decode(ACPJSON.self, from: data) else { return [] }
        // A server may batch: one array where one object would do.
        return value.arrayValue ?? [value]
    }

    /// The `data:` payloads of an SSE body, in order.
    ///
    /// Deliberately parsed from the whole body rather than streamed: a response stream carries the
    /// answer to *this* request and is closed after it, which is what the spec asks a server to do.
    /// A server that holds the stream open instead would hang here, and that is a bug worth seeing
    /// rather than a case worth quietly working around.
    private static func eventStream(_ data: Data) -> [ACPJSON] {
        var messages: [ACPJSON] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let value = try? JSONDecoder().decode(ACPJSON.self, from: Data(payload.utf8)) else { continue }
            messages.append(contentsOf: value.arrayValue ?? [value])
        }
        return messages
    }
}
