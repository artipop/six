import Foundation

/// The one request an OAuth redirect makes: `http://127.0.0.1:<port>/callback?code=…&state=…`.
///
/// A native application has nowhere else to be redirected to. The MCP spec inherits OAuth 2.1's
/// rule that a redirect URI is either HTTPS or loopback, which leaves loopback — and RFC 8252, the
/// BCP for native apps, says the same and says why: a private-use scheme can be claimed by any
/// other application on the machine, and a loopback port cannot.
///
/// It listens for exactly one request and then stops. Shaped after `MCPSocketListener`, one address
/// family over: `AF_INET` on 127.0.0.1 instead of a Unix socket, because a browser has to be able
/// to reach it as a URL.
nonisolated final class MCPLoopback: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "six.mcp.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    /// The port the kernel gave us, once `start` has returned.
    private(set) var port: UInt16 = 0

    enum Failure: LocalizedError {
        case cannotListen(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotListen(let reason): "Cannot listen for the sign-in redirect: \(reason)"
            case .cancelled: "Sign-in was cancelled."
            }
        }
    }

    /// Binds 127.0.0.1. `preferredPort` is the one a previous run registered with the authorization
    /// server; 0, or a port somebody else now holds, means the kernel picks and the client
    /// re-registers.
    func start(preferredPort: UInt16 = 0) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotListen("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = preferredPort.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian // 127.0.0.1, and nothing else
        var bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0, preferredPort != 0 {
            // Somebody else has the port we registered last time. Take any port and say so by
            // reporting a different one — the caller registers again.
            address.sin_port = 0
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            fd = -1
            throw Failure.cannotListen(String(cString: strerror(code)))
        }

        var assigned = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        port = UInt16(bigEndian: assigned.sin_port)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
    }

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    /// The query of the one request that arrives, or a failure if the caller gives up first.
    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        } onCancel: {
            stop(with: .failure(Failure.cancelled))
        }
    }

    func stop() { stop(with: .failure(Failure.cancelled)) }

    // MARK: The one request

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        defer { close(client) }

        // The request line is all that matters, and it is the first thing on the wire.
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let request = String(decoding: buffer[0..<count], as: UTF8.self)
        guard let line = request.split(whereSeparator: \.isNewline).first,
              let target = line.split(separator: " ").dropFirst().first else { return }

        let query = Self.query(of: String(target))
        let done = query["code"] != nil
        let page = Self.page(succeeded: done, message: query["error_description"] ?? query["error"])
        let body = Data(page.utf8)
        let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        var response = Data(head.utf8)
        response.append(body)
        response.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
        stop(with: .success(query))
    }

    private static func query(of target: String) -> [String: String] {
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return [:] }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }

    /// What the person is left looking at. Deliberately plain and in six's own words: the page after
    /// a sign-in is the one nobody designs and everybody sees.
    private static func page(succeeded: Bool, message: String?) -> String {
        let title = succeeded ? String(localized: "Signed in") : String(localized: "Sign-in failed")
        let detail = succeeded
            ? String(localized: "You can close this window and go back to six.")
            : (message ?? String(localized: "The authorization server did not return a code."))
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 0; height: 100vh;
                 display: flex; flex-direction: column; align-items: center; justify-content: center;
                 gap: .5rem; }
          h1 { font-size: 1.1rem; margin: 0; }
          p { margin: 0; opacity: .7; }
        </style></head>
        <body><h1>\(title)</h1><p>\(detail)</p></body></html>
        """
    }

    private func stop(with result: Result<[String: String], Error>) {
        let waiting: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        switch result {
        case .success(let query): waiting?.resume(returning: query)
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }
}
