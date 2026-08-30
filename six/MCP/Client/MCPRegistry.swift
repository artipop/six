import Foundation

/// The [official MCP Registry](https://registry.modelcontextprotocol.io) — the metadata index of
/// public servers, kept by Anthropic, GitHub, PulseMCP and Microsoft.
///
/// It answers "what servers are there", and that is all it answers. Its schema has `packages`,
/// `remotes`, `icons`, a repository and a website, and **no field for whether a server carries an
/// interface** — nowhere in the registry does it say that a tool draws something. So there is no
/// catalogue of MCP *apps* to read; the only way to know is to connect and look for
/// `_meta.ui.resourceUri`, which is what `MCPAppStore.probe` does with what comes back from here.
///
/// That asymmetry is why six bothers: a chat client shows the servers somebody curated for it, and
/// a browser can go and look.
nonisolated enum MCPRegistry {
    static let base = URL(string: "https://registry.modelcontextprotocol.io")!

    /// One published server, as much of it as six can use.
    struct Entry: Identifiable, Sendable, Hashable {
        var name: String
        var title: String?
        var description: String
        var version: String?
        var websiteURL: URL?
        var repositoryURL: URL?
        /// Ready-to-post endpoints, best first.
        var remotes: [URL]
        /// A local package six knows how to launch, when there is one.
        var package: Package?

        var id: String { name }
        var display: String { title ?? name }
        /// The publisher's namespace — `io.github.someone`, `ai.smithery` — which is the one piece
        /// of provenance the registry actually verifies.
        var namespace: String { name.split(separator: "/").first.map(String.init) ?? name }

        struct Package: Sendable, Hashable {
            var command: String
            var arguments: [String]
        }
    }

    /// One page, and where the next one starts.
    static func page(search query: String = "", limit: Int = 100, cursor: String? = nil) async throws -> (entries: [Entry], next: String?) {
        var components = URLComponents(url: base.appending(path: "v0/servers"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "version", value: "latest"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { components.queryItems?.append(URLQueryItem(name: "search", value: trimmed)) }
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let url = components.url else { return ([], nil) }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw JSONRPCError(code: -32000, message: "The registry answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = try JSONDecoder().decode(ACPJSON.self, from: data)
        let entries = (json["servers"]?.arrayValue ?? []).compactMap { entry(from: $0["server"] ?? $0) }
        return (entries, json["metadata"]?["nextCursor"]?.stringValue)
    }

    /// A page of results. `search` is a plain substring match on the registry's side.
    static func search(_ query: String, limit: Int = 30) async throws -> [Entry] {
        try await page(search: query, limit: limit).entries
    }

    /// Every server the registry has, up to `limit`, deduplicated by name — a publisher can have
    /// several versions listed and only the newest is worth asking.
    static func all(limit: Int, search query: String = "",
                    onPage: @Sendable (Int) -> Void = { _ in }) async throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        var cursor: String?
        while entries.count < limit {
            let (page, next) = try await page(search: query, limit: min(100, limit - entries.count), cursor: cursor)
            for entry in page where seen.insert(entry.name).inserted { entries.append(entry) }
            onPage(entries.count)
            guard let next, !page.isEmpty else { break }
            cursor = next
        }
        return entries
    }

    // MARK: Reading one entry

    private static func entry(from json: ACPJSON) -> Entry? {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        // Only Streamable HTTP. The registry also lists `sse`, the transport MCP replaced; six does
        // not speak it, and pretending otherwise would list servers it cannot open.
        let remotes = (json["remotes"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "streamable-http" }
            .compactMap { $0["url"]?.stringValue.flatMap(URL.init(string:)) }
        return Entry(
            name: name,
            title: json["title"]?.stringValue,
            description: json["description"]?.stringValue ?? "",
            version: json["version"]?.stringValue,
            websiteURL: json["websiteUrl"]?.stringValue.flatMap(URL.init(string:)),
            repositoryURL: json["repository"]?["url"]?.stringValue.flatMap(URL.init(string:)),
            remotes: remotes,
            package: (json["packages"]?.arrayValue ?? []).lazy.compactMap(package(from:)).first
        )
    }

    /// The command line for a package six can actually run.
    ///
    /// npm and PyPI only, through `npx` and `uvx` — the two runtimes an MCP server is published for
    /// that need nothing installed first. A Docker image or a `.mcpb` bundle is somebody's install
    /// step, and offering to launch one from a search field would be a promise six cannot keep.
    private static func package(from json: ACPJSON) -> Entry.Package? {
        guard json["transport"]?["type"]?.stringValue ?? "stdio" == "stdio",
              let identifier = json["identifier"]?.stringValue, !identifier.isEmpty else { return nil }
        let version = json["version"]?.stringValue
        let hint = json["runtimeHint"]?.stringValue
        let command: String
        var arguments: [String]
        switch json["registryType"]?.stringValue {
        case "npm":
            command = hint ?? "npx"
            arguments = ["-y", version.map { "\(identifier)@\($0)" } ?? identifier]
        case "pypi":
            command = hint ?? "uvx"
            arguments = version.map { ["\(identifier)==\($0)"] } ?? [identifier]
        default:
            return nil
        }
        arguments += (json["packageArguments"]?.arrayValue ?? []).flatMap(argument(from:))
        return Entry.Package(command: command, arguments: arguments)
    }

    /// One declared argument. A value the publisher left for the user to fill in is skipped rather
    /// than passed as its own placeholder text — a server started with `<your-api-key>` on the
    /// command line fails in a way nobody can read.
    private static func argument(from json: ACPJSON) -> [String] {
        let value = json["value"]?.stringValue ?? json["default"]?.stringValue
        switch json["type"]?.stringValue {
        case "named":
            guard let name = json["name"]?.stringValue else { return [] }
            guard let value, !value.contains("<") else { return json["isRequired"]?.boolValue == true ? [] : [name] }
            return json["isRepeated"]?.boolValue == true ? [name, value] : [name, value]
        default:
            guard let value, !value.contains("<") else { return [] }
            return [value]
        }
    }
}

extension MCPRegistry.Entry {
    /// What six would add to its list of servers, when there is a way in at all.
    ///
    /// Remote first: a URL costs a POST, while a package costs a download and a process. `id` is the
    /// last path component of the registry name, which is what prefixes this server's tools for the
    /// agent — `io.github.someone/weather` becomes `weather`.
    func definition(preferringRemote: Bool = true) -> MCPServerDefinition? {
        let identifier = String(name.split(separator: "/").last ?? "server")
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let id = String(identifier).split(separator: "-").joined(separator: "-")
        if preferringRemote, let url = remotes.first {
            return MCPServerDefinition(id: id, name: display, url: url)
        }
        if let package {
            return MCPServerDefinition(id: id, name: display, command: package.command, arguments: package.arguments)
        }
        if let url = remotes.first {
            return MCPServerDefinition(id: id, name: display, url: url)
        }
        return nil
    }

    var isRemote: Bool { !remotes.isEmpty }
}
