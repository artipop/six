import Foundation

/// `six --mcp-probe …`: connect to an MCP server, say what it carries, and stop.
///
/// The first phase of MCP Apps has no interface to look at — the whole of it is a handshake, a tool
/// list and an HTML document — so this is where it is checked. Like `--mcp`, it runs before AppKit
/// is touched: no Dock icon, no window, no running browser needed.
///
/// ```sh
/// six --mcp-probe example:basic-vanillajs
/// six --mcp-probe npx -y @modelcontextprotocol/server-map --stdio
/// six --mcp-probe http://localhost:3001/mcp          # a remote server, over Streamable HTTP
/// six --mcp-probe -- uv run --directory ~/code/ext-apps/examples/qr-server qr-server --stdio
/// ```
nonisolated enum MCPProbe {
    static let flag = "--mcp-probe"
    /// Sweeping the registry into `MCPAppCatalog.json` — see `buildCatalog`.
    static let catalogFlag = "--mcp-catalog"

    static var isRequested: Bool { CommandLine.arguments.dropFirst().contains(flag) }
    static var isCatalogRequested: Bool { CommandLine.arguments.dropFirst().contains(catalogFlag) }

    /// Sweeps the registry and writes the catalogue. A separate entry point from `run`, because it
    /// takes no server: it goes and finds them.
    static func runCatalog() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: catalogFlag) else { exit(2) }
        let rest = Array(arguments[arguments.index(after: index)...])
        let status = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            status.value = await buildCatalog(rest)
            semaphore.signal()
        }
        semaphore.wait()
        exit(status.value)
    }

    static func run() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: flag) else { exit(2) }
        var rest = Array(arguments[arguments.index(after: index)...])
        if rest.first == "--" { rest.removeFirst() }
        guard let first = rest.first else {
            fail("""
                 usage: six \(flag) [--] <command> [args…]
                        six \(flag) <url>              # a remote server, over Streamable HTTP
                        six \(flag) example:<name>     # a published ext-apps example, via npx
                 """)
        }

        let definition: MCPServerDefinition
        if first.hasPrefix("example:") {
            definition = .example(String(first.dropFirst("example:".count)))
        } else if first.hasPrefix("http://") || first.hasPrefix("https://"), let url = URL(string: first) {
            // Everything after the URL is `name: value`, for the one header a token goes in.
            var headers: [String: String] = [:]
            for argument in rest.dropFirst() {
                guard let colon = argument.firstIndex(of: ":") else { continue }
                headers[String(argument[..<colon])] = String(argument[argument.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            definition = MCPServerDefinition(id: url.host() ?? "remote", url: url, headers: headers)
        } else {
            definition = MCPServerDefinition(id: "probe", command: first, arguments: Array(rest.dropFirst()))
        }

        let status = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            status.value = await probe(definition)
            semaphore.signal()
        }
        semaphore.wait()
        exit(status.value)
    }

    // MARK: Building the catalogue

    /// `six --mcp-catalog` — sweeps the registry, asks every remote server what it carries, and
    /// writes the ones with an interface as JSON. This is where `MCPAppCatalog.json` comes from.
    ///
    /// Progress goes to stderr and the catalogue to stdout, so the whole thing is a pipe:
    ///
    /// ```sh
    /// six --mcp-catalog --limit 500 > six/MCP/Client/MCPAppCatalog.json
    /// ```
    private static func buildCatalog(_ arguments: [String]) async -> Int32 {
        var limit = 300
        var concurrency = 8
        var timeout: TimeInterval = 12
        var out: String?
        var query = ""
        var index = arguments.startIndex
        while index < arguments.endIndex {
            switch arguments[index] {
            case "--limit":
                index += 1
                limit = arguments.indices.contains(index) ? Int(arguments[index]) ?? limit : limit
            case "--out":
                index += 1
                out = arguments.indices.contains(index) ? arguments[index] : nil
            case "--concurrency":
                index += 1
                concurrency = arguments.indices.contains(index) ? Int(arguments[index]) ?? concurrency : concurrency
            case "--timeout":
                index += 1
                timeout = arguments.indices.contains(index) ? Double(arguments[index]) ?? timeout : timeout
            default:
                query = query.isEmpty ? arguments[index] : query + " " + arguments[index]
            }
            index += 1
        }
        do {
            let catalog = try await MCPCatalog.sweep(limit: limit, query: query, concurrency: concurrency,
                                                     timeout: timeout) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            let data = try MCPCatalog.encoder.encode(catalog)
            if let out {
                try data.write(to: URL(fileURLWithPath: out), options: .atomic)
                FileHandle.standardError.write(Data("wrote \(catalog.entries.count) entries to \(out)\n".utf8))
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return 0
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: The probe itself

    private static func probe(_ definition: MCPServerDefinition) async -> Int32 {
        let client = MCPClient(definition: definition)
        say(definition.isRemote ? "→ \(definition.location)" : "$ \(definition.location)")
        do {
            let info = try await client.connect()
            let title = info.title.map { "\($0) (\(info.name))" } ?? info.name
            say("\n\(title) \(info.version ?? "")".trimmingCharacters(in: .whitespaces))
            say("  protocol \(info.protocolVersion)"
                + "   ui extension \(info.acknowledgedUIExtension ? "acknowledged" : "not echoed")")
            if let instructions = info.instructions, !instructions.isEmpty {
                say("  instructions: \(oneLine(instructions, limit: 160))")
            }

            let tools = try await client.listTools()
            say("\ntools (\(tools.count)):")
            for tool in tools {
                let marks = tool.visibility.map(\.rawValue).sorted().joined(separator: ", ")
                say("  \(tool.hasApp ? "▣" : "·") \(tool.name)"
                    + (tool.title.map { " — \($0)" } ?? "")
                    + "   [\(marks)]")
                if let description = tool.description, !description.isEmpty {
                    say("      \(oneLine(description, limit: 120))")
                }
                if let uri = tool.uiResourceURI { say("      \(uri)") }
            }

            let apps = tools.filter(\.hasApp)
            guard let first = apps.first, let uri = first.uiResourceURI else {
                say("\nNo tool on this server declares a ui:// resource — nothing to render.")
                await client.close()
                return 0
            }
            if apps.count > 1 { say("\n\(apps.count) tools carry an interface; reading the first.") }

            let resource = try await client.readUIResource(uri)
            let bytes = resource.html.utf8.count
            say("\n\(resource.uri)")
            say("  \(resource.mimeType)   \(bytes) bytes")
            say("  csp: \(resource.csp.header)")
            if !resource.permissions.isEmpty {
                let asked = [
                    resource.permissions.camera ? "camera" : nil,
                    resource.permissions.microphone ? "microphone" : nil,
                    resource.permissions.geolocation ? "geolocation" : nil,
                    resource.permissions.clipboardWrite ? "clipboard-write" : nil,
                ].compactMap { $0 }
                say("  asks for: \(asked.joined(separator: ", "))")
            }
            if let domain = resource.domain { say("  domain: \(domain)") }
            if let border = resource.prefersBorder { say("  prefers border: \(border)") }
            say("  \(oneLine(resource.html, limit: 200))")

            // Calling it is the last thing the app window will do differently: a tool with nothing
            // required can be called blind, and its result is what a View would be handed.
            if requiresNoArguments(first) {
                let result = try await client.callTool(first.name)
                say("\ntools/call \(first.name) →")
                for block in result["content"]?.arrayValue ?? [] {
                    let kind = block["type"]?.stringValue ?? "?"
                    let text = block["text"]?.stringValue ?? ""
                    say("  \(kind): \(oneLine(text, limit: 200))")
                }
                if let structured = result["structuredContent"] {
                    say("  structured: \(oneLine(structured.description, limit: 200))")
                }
            } else {
                say("\n\(first.name) takes required arguments; not calling it.")
            }

            await client.close()
            return 0
        } catch {
            let stderr = await client.recentStderr
            fail("\(error.localizedDescription)" + (stderr.isEmpty ? "" : "\n--- server stderr ---\n\(stderr)"))
        }
    }

    private static func requiresNoArguments(_ tool: MCPTool) -> Bool {
        (tool.inputSchema?["required"]?.arrayValue ?? []).isEmpty
    }

    // MARK: Saying things

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("six \(flag): \(message)\n".utf8))
        exit(1)
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let flattened = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    /// The exit status, written from the task and read after the semaphore — the one piece of state
    /// that crosses the boundary in a function whose whole job is to block until it is done.
    private final class Box: @unchecked Sendable {
        var value: Int32 = 0
    }
}
