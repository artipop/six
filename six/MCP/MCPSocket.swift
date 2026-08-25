import Foundation

/// Where the running app listens for MCP clients: a Unix socket, so `six --mcp` (and anything else
/// local) can reach the browser without ports. Override with `SIX_MCP_SOCKET`.
nonisolated enum MCPSocket {
    static var path: String {
        if let custom = ProcessInfo.processInfo.environment["SIX_MCP_SOCKET"], !custom.isEmpty { return custom }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "six/mcp.sock").path
    }

    /// `sockaddr_un` for `path`; nil when the path is too long for the kernel's 104-byte field.
    static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Connects to the socket; nil if nobody is listening.
    static func connect(path: String) -> Int32? {
        guard var addr = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

/// Accepts connections on the Unix socket and hands each one over as a `FileHandle`.
nonisolated final class MCPSocketListener: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "six.mcp.listener")

    init(path: String = MCPSocket.path) {
        self.path = path
    }

    func start(onConnection: @escaping @Sendable (FileHandle) -> Void) throws {
        guard var addr = MCPSocket.address(for: path) else {
            throw JSONRPCError.internalError("MCP socket path is too long: \(path)")
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A stale socket file from a previous run would make bind() fail; a live one means another
        // instance is serving and we leave it alone.
        if let other = MCPSocket.connect(path: path) {
            close(other)
            throw JSONRPCError.internalError("Another six is already serving MCP at \(path)")
        }
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw JSONRPCError.internalError("socket() failed: \(errno)") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            fd = -1
            throw JSONRPCError.internalError("bind/listen failed on \(path): \(String(cString: strerror(code)))")
        }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [fd] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            onConnection(FileHandle(fileDescriptor: client, closeOnDealloc: true))
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    deinit { stop() }
}
