import Foundation

/// The other half of [MCP](https://modelcontextprotocol.io) in six: not the browser answering an
/// agent (`MCPServer`), but the browser *asking* — a host for servers that carry interfaces.
///
/// [MCP Apps](https://github.com/modelcontextprotocol/ext-apps) (SEP-1865) is an extension: a tool
/// points at a `ui://` resource, the resource is an HTML document, and the host shows it instead of
/// the tool's text. See [mcp-apps.md](../../../docs/mcp-apps.md) for the shape of the whole thing.
nonisolated enum MCPApps {
    /// The extension's identifier, as it goes into `capabilities.extensions` on `initialize`.
    static let extensionID = "io.modelcontextprotocol/ui"
    /// The one content type the extension defines. Everything else is reserved for later.
    static let mimeType = "text/html;profile=mcp-app"
    /// Core protocol versions six can speak, newest first. The extension's own revision
    /// (`2026-01-26`) is a different number and is deliberately not compared against these.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let clientInfo: ACPJSON = ["name": "six", "title": "Six Browser", "version": "1.0"]

    /// Runs `work`, or gives up on it.
    ///
    /// Every place six talks to a server it did not write needs this. A URL that accepts the
    /// connection and then says nothing is not an error anything reports — it is a task that never
    /// returns — and one of those in a list of thirty is a list that never finishes.
    static func withDeadline<T: Sendable>(_ duration: Duration,
                                          _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw JSONRPCError(code: -32000, message: "timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Where a server is and how to reach it: a command line to launch, or a URL to post to.
///
/// The command form is the same shape as `ACPAgentDefinition` minus the toolchain fields, and runs
/// with the user's shell environment so `npx` and friends are on PATH.
nonisolated struct MCPServerDefinition: Identifiable, Hashable, Codable, Sendable {
    /// The name this server is known by — what prefixes its tools, so ASCII and no spaces.
    var id: String
    /// What a person reads. Defaults to `id`.
    var name: String
    var command: String = ""
    var arguments: [String] = []
    var environment: [String: String] = [:]
    /// A remote server's endpoint. When this is set the command is not used at all.
    var url: URL?
    /// Headers sent with every request — where an API key or a bearer token goes, until there is
    /// OAuth. Not shown in listings.
    var headers: [String: String] = [:]

    init(id: String, name: String? = nil, command: String, arguments: [String] = [],
         environment: [String: String] = [:]) {
        self.id = id
        self.name = name ?? id
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    init(id: String, name: String? = nil, url: URL, headers: [String: String] = [:]) {
        self.id = id
        self.name = name ?? id
        self.url = url
        self.headers = headers
    }

    /// The server a restored window remembers.
    init(_ saved: AppWindowSnapshot) {
        id = saved.serverID
        name = saved.serverName
        url = saved.url
        command = saved.command
        arguments = saved.commandArguments
    }

    /// A remote server, or a local process.
    var isRemote: Bool { url != nil }
    /// What to show for "where this is".
    var location: String { url?.absoluteString ?? shellCommandLine }

    /// The command line as a person would read it. For showing, not for running: `MCPServerProcess`
    /// spawns the program directly rather than handing a string to a shell. Anything but a plain
    /// word is quoted, so what is shown is what a shell would actually run.
    var shellCommandLine: String {
        ([command] + arguments).map { argument in
            let isPlain = !argument.isEmpty && argument.allSatisfy {
                $0.isLetter || $0.isNumber || "-_./@:+=".contains($0)
            }
            return isPlain ? argument : "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }

    /// One of the published examples, launched straight from npm — nothing to clone or build.
    /// `MCPServerDefinition.example("basic-vanillajs")` is the smallest app there is.
    static func example(_ name: String) -> MCPServerDefinition {
        MCPServerDefinition(id: name, command: "npx",
                            arguments: ["-y", "--silent", "@modelcontextprotocol/server-\(name)", "--stdio"])
    }
}

/// A tool as the server described it, with the extension's metadata read out of `_meta`.
// Equatable but not `Hashable`: `inputSchema` is an `ACPJSON`, which has no hash of its own, and a
// tool is identified by its name anyway.
nonisolated struct MCPTool: Identifiable, Equatable, Sendable {
    /// Who may call this tool (`_meta.ui.visibility`, defaulting to both).
    enum Visibility: String, Hashable, Sendable {
        /// Visible to, and callable by, the agent.
        case model
        /// Callable by an app — and only by an app of the same server.
        case app
    }

    var name: String
    var title: String?
    var description: String?
    var inputSchema: ACPJSON?
    /// `_meta.ui.resourceUri`: the `ui://` document that draws this tool's result, when there is one.
    var uiResourceURI: String?
    var visibility: Set<Visibility>
    /// `annotations.readOnlyHint` from core MCP: the tool does not change anything. The one signal
    /// in the protocol that says whether asking again is safe, which is exactly the question a
    /// restored window poses.
    var isReadOnly: Bool

    var id: String { name }
    /// A tool with an interface behind it — the reason any of this exists.
    var hasApp: Bool { uiResourceURI != nil }
    /// What to say in a list: the server's own human-readable name, or the wire name.
    var display: String { title ?? name }

    init(json: ACPJSON) {
        name = json["name"]?.stringValue ?? ""
        title = json["title"]?.stringValue
        description = json["description"]?.stringValue
        inputSchema = json["inputSchema"]
        let ui = json["_meta"]?["ui"]
        // The flat `_meta["ui/resourceUri"]` is deprecated but still shipped by live servers
        // alongside the nested form, so both are read and the nested one wins.
        uiResourceURI = ui?["resourceUri"]?.stringValue ?? json["_meta"]?["ui/resourceUri"]?.stringValue
        isReadOnly = json["annotations"]?["readOnlyHint"]?.boolValue ?? false
        if let declared = ui?["visibility"]?.arrayValue {
            visibility = Set(declared.compactMap { $0.stringValue }.compactMap(Visibility.init(rawValue:)))
        } else {
            visibility = [.model, .app]
        }
    }
}

/// A `ui://` resource: one self-contained HTML document plus what the host is allowed to let it do.
nonisolated struct MCPUIResource: Hashable, Sendable {
    var uri: String
    var mimeType: String
    var html: String
    var csp: CSP
    var permissions: Permissions
    /// `_meta.ui.domain` — a stable origin the app asks for (OAuth callbacks, API key allowlists).
    var domain: String?
    /// Whether the app wants the host to draw a border and background around it.
    var prefersBorder: Bool?

    /// The origins the server declares it needs. Absent means none: the default is a closed door.
    struct CSP: Hashable, Sendable {
        var connectDomains: [String] = []
        var resourceDomains: [String] = []
        var frameDomains: [String] = []
        var baseUriDomains: [String] = []
        init() {}

        init(json: ACPJSON?) {
            func list(_ key: String) -> [String] {
                (json?[key]?.arrayValue ?? []).compactMap(\.stringValue)
            }
            connectDomains = list("connectDomains")
            resourceDomains = list("resourceDomains")
            frameDomains = list("frameDomains")
            baseUriDomains = list("baseUriDomains")
        }

        /// The `Content-Security-Policy` header value for this app.
        ///
        /// One policy, and it is the specification's: `default-src 'none'`, the document's own
        /// scripts and styles, images and media from `data:`, and no network. A declared domain
        /// only ever *adds* an origin to the directive the spec maps it to; nothing else is added
        /// to anything, ever.
        ///
        /// What that costs is worth writing down, because it is not small and it is not six's to
        /// fix. CesiumJS dies on `Refused to evaluate a string as JavaScript`; every WebGL app that
        /// decodes tiles in a worker dies without `blob:`; the reference host in `ext-apps` ships a
        /// looser floor than the prose, so this is stricter than what app authors test against, and
        /// some of the specification's own examples do not run under it. There is no field in
        /// `ui.csp` for `'unsafe-eval'`, `blob:` or `worker-src`, so an app cannot declare its way
        /// out either — the gap is upstream's. six enforces what is written.
        var header: String {
            func source(_ base: String, _ domains: [String]) -> String {
                ([base] + domains).joined(separator: " ")
            }
            var directives = [
                "default-src 'none'",
                source("script-src 'self' 'unsafe-inline'", resourceDomains),
                source("style-src 'self' 'unsafe-inline'", resourceDomains),
                source("img-src 'self' data:", resourceDomains),
                source("media-src 'self' data:", resourceDomains),
                // Not in the spec's own block, and only ever narrower than the `default-src 'none'`
                // it would otherwise fall through to.
                "object-src 'none'",
            ]
            // `resourceDomains` covers fonts too, but with nothing declared there is no font
            // directive at all: `default-src 'none'` is what the spec leaves in its place.
            if !resourceDomains.isEmpty { directives.append(source("font-src 'self'", resourceDomains)) }
            directives.append(connectDomains.isEmpty
                              ? "connect-src 'none'"
                              : source("connect-src", connectDomains))
            directives.append(frameDomains.isEmpty ? "frame-src 'none'" : source("frame-src", frameDomains))
            directives.append(baseUriDomains.isEmpty ? "base-uri 'self'" : source("base-uri", baseUriDomains))
            return directives.joined(separator: "; ")
        }
    }

    /// Browser capabilities the app asks for. Asking is not getting: six answers these through
    /// `SitePermissions`, the same way it answers a web page.
    struct Permissions: Hashable, Sendable {
        var camera = false
        var microphone = false
        var geolocation = false
        var clipboardWrite = false

        init() {}

        init(json: ACPJSON?) {
            camera = json?["camera"] != nil
            microphone = json?["microphone"] != nil
            geolocation = json?["geolocation"] != nil
            clipboardWrite = json?["clipboardWrite"] != nil
        }

        var isEmpty: Bool { !(camera || microphone || geolocation || clipboardWrite) }
    }

    /// Reads one entry of a `resources/read` response.
    init?(contents json: ACPJSON) {
        guard let uri = json["uri"]?.stringValue else { return nil }
        let text: String
        if let value = json["text"]?.stringValue {
            text = value
        } else if let blob = json["blob"]?.stringValue, let data = Data(base64Encoded: blob) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            return nil
        }
        self.uri = uri
        mimeType = json["mimeType"]?.stringValue ?? MCPApps.mimeType
        html = text
        let ui = json["_meta"]?["ui"]
        csp = CSP(json: ui?["csp"])
        permissions = Permissions(json: ui?["permissions"])
        domain = ui?["domain"]?.stringValue
        prefersBorder = ui?["prefersBorder"]?.boolValue
    }

    /// Is this actually an app, rather than some other resource that happens to be HTML?
    var isApp: Bool { mimeType.hasPrefix("text/html") && mimeType.contains("profile=mcp-app") }
}
