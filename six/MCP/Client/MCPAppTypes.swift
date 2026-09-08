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

/// An OAuth client somebody created in a console and typed in, for a server that hands out none.
///
/// The spec assumes dynamic client registration (RFC 7591), and for good reason: six is a desktop
/// application meeting servers it has never heard of, so it asks for a client id at the moment it
/// needs one. Providers whose clients are created by hand — Google's Workspace servers are the case
/// this was written for — have no registration endpoint at all, and there the id and the secret come
/// from the person instead.
///
/// The port is part of the credential rather than an implementation detail. Such a provider stores
/// the redirect URI exactly and refuses anything else, so the loopback listener has to come back on
/// the same port every time; `redirectURI` is the string that gets pasted into the console.
nonisolated struct MCPOAuthClient: Hashable, Codable, Sendable {
    var clientID: String
    var redirectPort: UInt16
    /// The authorization server, for a resource server that names none. RFC 9728 says a server
    /// should publish `/.well-known/oauth-protected-resource`, and a provider old enough to have no
    /// registration endpoint is often old enough not to publish that either; then the only way to
    /// find the endpoints is to be told where they are (`https://accounts.google.com` for Google).
    var issuer: URL?
    /// What to ask for when the server's own metadata names no scopes. Google's do not, and its
    /// authorization endpoint refuses a request that asks for nothing.
    var scopes: [String] = []

    var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }

    /// A port of this server's own, in the range nothing else claims (RFC 6335's dynamic range),
    /// derived from the id so that it survives a restart and a reinstall.
    ///
    /// FNV-1a and not `Hasher`: Swift seeds that one per process, so the same server would get a
    /// different port on every launch and every registered redirect URI would stop matching.
    static func port(for serverID: String) -> UInt16 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in serverID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return UInt16(49152 + hash % 16000)
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
    /// The OAuth client six was handed, for a server that does not give out clients of its own.
    /// Absent — the normal case — means six registers itself when the server asks for a sign-in.
    /// The secret that goes with it is in the Keychain, never here: this struct is written to the
    /// settings table as JSON.
    var oauth: MCPOAuthClient?

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
                (json?[key]?.arrayValue ?? []).compactMap(\.stringValue).filter(CSP.isPlausibleSource)
            }
            connectDomains = list("connectDomains")
            resourceDomains = list("resourceDomains")
            frameDomains = list("frameDomains")
            baseUriDomains = list("baseUriDomains")
        }

        /// Whether a declared source is one six is willing to put in a policy.
        ///
        /// These lists are strings a server wrote, and they are joined into a header — so a value
        /// is not data, it is policy. `"https://x; script-src *"` is a second directive; `"'unsafe-eval'"`
        /// is the one keyword this whole policy exists to withhold, and it would land in `script-src`
        /// because that is where `resourceDomains` goes. A source therefore has to look like the
        /// origin the extension says it is, and anything else is dropped rather than argued with.
        static func isPlausibleSource(_ source: String) -> Bool {
            guard !source.isEmpty, source.count <= 512, source != "*" else { return false }
            return source.unicodeScalars.allSatisfy { scalar in
                // Printable ASCII, so no space and no control character can split a source in two,
                // less the punctuation that ends one and begins something else. `'` is in there
                // because it is how every CSP keyword — `'unsafe-eval'` above all — is spelled.
                (0x21...0x7E).contains(scalar.value) && !";'\",\\<>".unicodeScalars.contains(scalar)
            }
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
        /// out either — the gap is upstream's, and `isPlausibleSource` is what keeps a server from
        /// writing its way out through a domain list. six enforces what is written.
        var header: String {
            // Filtered here as well as at parse time: this is the line where a string becomes
            // policy, and it is the only place the guarantee is worth making.
            func source(_ base: String, _ domains: [String]) -> String {
                ([base] + domains.filter(Self.isPlausibleSource)).joined(separator: " ")
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
            if resourceDomains.contains(where: Self.isPlausibleSource) {
                directives.append(source("font-src 'self'", resourceDomains))
            }
            let connect = connectDomains.filter(Self.isPlausibleSource)
            let frames = frameDomains.filter(Self.isPlausibleSource)
            let bases = baseUriDomains.filter(Self.isPlausibleSource)
            directives.append(connect.isEmpty ? "connect-src 'none'" : source("connect-src", connect))
            directives.append(frames.isEmpty ? "frame-src 'none'" : source("frame-src", frames))
            directives.append(bases.isEmpty ? "base-uri 'self'" : source("base-uri", bases))
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
