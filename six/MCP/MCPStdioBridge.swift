import Foundation

/// `six --mcp`: the app binary acting as a stdio MCP server. It is a byte pump — MCP over stdio and
/// the app's Unix socket both speak newline-delimited JSON-RPC, so nothing is parsed here; the
/// running app answers. If the app isn't running it is launched and waited for.
nonisolated enum MCPStdioBridge {
    static let flag = "--mcp"

    static var isRequested: Bool { CommandLine.arguments.dropFirst().contains(flag) }

    /// How an ACP agent should launch this server — the very binary that is running.
    static var acpServer: ACP.MCPServer {
        ACP.MCPServer(name: "six", command: Bundle.main.executableURL?.path ?? CommandLine.arguments[0], args: [flag])
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let path = MCPSocket.path
        guard let sock = waitForApp(path: path) else {
            FileHandle.standardError.write(Data("six --mcp: could not reach the browser at \(path)\n".utf8))
            exit(1)
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { pump(from: STDIN_FILENO, to: sock); shutdown(sock, SHUT_WR); group.leave() }
        group.enter()
        DispatchQueue.global().async { pump(from: sock, to: STDOUT_FILENO); group.leave() }
        group.wait()
        close(sock)
        exit(0)
    }

    private static func waitForApp(path: String) -> Int32? {
        if let fd = MCPSocket.connect(path: path) { return fd }
        launchApp()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let fd = MCPSocket.connect(path: path) { return fd }
        }
        return nil
    }

    private static func launchApp() {
        // The bundle is two directories above the executable (six.app/Contents/MacOS/six).
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", bundle.path] // -g: don't steal focus from the agent's terminal
        try? open.run()
        open.waitUntilExit()
    }

    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + written, count - written) }
                guard n > 0 else { return }
                written += n
            }
        }
    }
}
