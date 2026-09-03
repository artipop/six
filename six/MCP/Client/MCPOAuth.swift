// CryptoKit and the Keychain are Apple's, and PKCE needs both a SHA-256 and a source of
// randomness. A front end on another platform would reach for swift-crypto here; until one
// does, this whole file is simply absent there rather than half-ported.
#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// OAuth 2.1 for a remote MCP server, as [the MCP spec](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
/// defines it: the **server** is a resource server, and the **client** — six — is the OAuth client.
///
/// It is a transport-level thing and only for HTTP. A stdio server explicitly does *not* use this:
/// it is a process six launched, and its credentials come from the environment it was launched
/// with. Nothing here ever runs for a `MCPStdioTransport`.
///
/// The flow, once, in order:
///
/// 1. A request comes back `401` with `WWW-Authenticate: Bearer resource_metadata="…"`.
/// 2. That URL (or `/.well-known/oauth-protected-resource`) names the authorization servers.
/// 3. The authorization server's own metadata names its endpoints (RFC 8414, with OpenID discovery
///    as the fallback so many real providers work).
/// 4. six registers itself if the server allows it (RFC 7591) — there is no client id to hardcode
///    when the servers are not known in advance.
/// 5. The authorization page opens in a window of the strip, with PKCE and a `resource` parameter.
/// 6. The redirect lands on a loopback port six is listening on, and the code is exchanged.
///
/// The `resource` parameter is not optional politeness: it is what binds the token to *this* server,
/// so a token six holds for one cannot be replayed against another.
nonisolated enum MCPOAuth {
    static let clientName = "six"

    // MARK: What the servers say about themselves

    struct ResourceMetadata: Decodable, Sendable {
        var resource: String?
        var authorizationServers: [URL]?
        var scopesSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case resource
            case authorizationServers = "authorization_servers"
            case scopesSupported = "scopes_supported"
        }
    }

    struct ServerMetadata: Decodable, Sendable {
        var issuer: String?
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopesSupported: [String]?
        var codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case scopesSupported = "scopes_supported"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    /// What six keeps between runs: who it registered as, and the token it was given.
    struct Grant: Codable, Sendable {
        var issuer: String
        var clientID: String
        var clientSecret: String?
        /// The loopback URI registered with the authorization server — the same port next time, or
        /// the registration no longer matches.
        var redirectURI: String
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var scope: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // A token about to expire is a token that will expire mid-request.
            return expiresAt.timeIntervalSinceNow < 30
        }

        var port: UInt16 { UInt16(URLComponents(string: redirectURI)?.port ?? 0) }
    }

    enum Failure: LocalizedError {
        case noAuthorizationServer(URL)
        case noMetadata(URL)
        case noRegistration(String)
        case denied(String)
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .noAuthorizationServer(let url):
                "\(url.host() ?? url.absoluteString) asks for authorization but names no authorization server."
            case .noMetadata(let url):
                "No OAuth metadata at \(url.host() ?? url.absoluteString)."
            case .noRegistration(let issuer):
                "\(issuer) supports neither dynamic client registration nor a client id six could use."
            case .denied(let reason):
                "Authorization was refused: \(reason)"
            case .stateMismatch:
                "The authorization server answered a request six did not make."
            }
        }
    }

    // MARK: Discovery

    /// The `resource_metadata` URL out of a `WWW-Authenticate` header, when the server named one.
    static func resourceMetadataURL(fromChallenge challenge: String?) -> URL? {
        guard let challenge, let range = challenge.range(of: "resource_metadata=") else { return nil }
        var value = String(challenge[range.upperBound...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
        } else if let end = value.firstIndex(of: ",") {
            value = String(value[..<end]).trimmingCharacters(in: .whitespaces)
        }
        return URL(string: value)
    }

    /// RFC 9728. The header's URL when there is one, otherwise the well-known paths for this server —
    /// with the path-suffixed form first, since one host can carry several MCP servers.
    static func resourceMetadata(for endpoint: URL, challenge: String?) async -> ResourceMetadata? {
        var candidates: [URL] = []
        if let named = resourceMetadataURL(fromChallenge: challenge) { candidates.append(named) }
        candidates += wellKnown("oauth-protected-resource", for: endpoint)
        for candidate in candidates {
            if let metadata: ResourceMetadata = await fetch(candidate) { return metadata }
        }
        return nil
    }

    /// RFC 8414, then OpenID Connect discovery: between them they cover what providers actually
    /// serve. Both well-known forms are tried — the path-inserted one the RFC specifies, and the
    /// path-appended one much of the world implements.
    static func serverMetadata(for issuer: URL) async -> ServerMetadata? {
        for name in ["oauth-authorization-server", "openid-configuration"] {
            for candidate in wellKnown(name, for: issuer) {
                if let metadata: ServerMetadata = await fetch(candidate) { return metadata }
            }
        }
        return nil
    }

    /// `https://host/.well-known/<name>/some/path` and `https://host/some/path/.well-known/<name>`.
    private static func wellKnown(_ name: String, for url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.query = nil
        components.fragment = nil
        var candidates: [URL] = []
        components.path = "/.well-known/\(name)" + path
        if let inserted = components.url { candidates.append(inserted) }
        components.path = path + "/.well-known/\(name)"
        if let appended = components.url, appended != candidates.first { candidates.append(appended) }
        if !path.isEmpty {
            components.path = "/.well-known/\(name)"
            if let root = components.url { candidates.append(root) }
        }
        return candidates
    }

    /// An authorization server endpoint must be HTTPS — OAuth 2.1 says so, and following a
    /// plaintext one would hand somebody on the network the token. Loopback is the exception every
    /// implementation makes and the only one worth making: nothing leaves the machine.
    static func isSafeEndpoint(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        guard isSafeEndpoint(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Registration

    /// RFC 7591. Public client, no secret to keep: six is a desktop application and cannot hold one.
    static func register(with metadata: ServerMetadata, redirectURI: String) async throws -> (id: String, secret: String?) {
        guard let endpoint = metadata.registrationEndpoint, isSafeEndpoint(endpoint) else {
            throw Failure.noRegistration(metadata.issuer ?? "The authorization server")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["client_id"] as? String else {
            throw Failure.denied(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (id, json["client_secret"] as? String)
    }

    // MARK: The authorization request

    struct PKCE: Sendable {
        let verifier: String
        let challenge: String
        let state: String

        init() {
            verifier = Self.random(64)
            let digest = SHA256.hash(data: Data(verifier.utf8))
            challenge = Data(digest).base64URLEncoded
            state = Self.random(32)
        }

        private static func random(_ count: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            return Data(bytes).base64URLEncoded
        }
    }

    static func authorizationURL(metadata: ServerMetadata, clientID: String, redirectURI: String,
                                 resource: String, scope: String?, pkce: PKCE) -> URL? {
        guard isSafeEndpoint(metadata.authorizationEndpoint),
              var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            // RFC 8707. Sent whether or not the server is known to understand it — the spec says
            // MUST, and a server that ignores it is no worse off.
            URLQueryItem(name: "resource", value: resource),
        ]
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        return components.url
    }

    // MARK: Tokens

    static func exchange(code: String, metadata: ServerMetadata, clientID: String, clientSecret: String?,
                         redirectURI: String, resource: String, verifier: String) async throws -> Grant {
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": resource,
        ]
        if let clientSecret { form["client_secret"] = clientSecret }
        return try await token(form, metadata: metadata, clientID: clientID, clientSecret: clientSecret,
                               redirectURI: redirectURI, keeping: nil)
    }

    static func refresh(_ grant: Grant, metadata: ServerMetadata, resource: String) async throws -> Grant {
        guard let refreshToken = grant.refreshToken else { throw Failure.denied("no refresh token") }
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": grant.clientID,
            "resource": resource,
        ]
        if let secret = grant.clientSecret { form["client_secret"] = secret }
        return try await token(form, metadata: metadata, clientID: grant.clientID, clientSecret: grant.clientSecret,
                               redirectURI: grant.redirectURI, keeping: grant)
    }

    private static func token(_ form: [String: String], metadata: ServerMetadata, clientID: String,
                              clientSecret: String?, redirectURI: String, keeping previous: Grant?) async throws -> Grant {
        guard isSafeEndpoint(metadata.tokenEndpoint) else {
            throw Failure.denied("the token endpoint is not served over HTTPS")
        }
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let reason = (body["error_description"] as? String) ?? (body["error"] as? String)
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure.denied(reason)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init)
        return Grant(
            issuer: metadata.issuer ?? metadata.tokenEndpoint.host() ?? "",
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            accessToken: accessToken,
            // A server that rotates refresh tokens sends a new one; one that does not expects the
            // old one to keep working, so it is kept rather than dropped.
            refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            scope: (json["scope"] as? String) ?? previous?.scope
        )
    }

    /// The canonical URI of the server the token is for: no fragment, no trailing slash, lowercase
    /// scheme and host. This is what goes in `resource`, and what the server checks the token
    /// against.
    static func canonicalResource(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") { components.path = String(components.path.dropLast()) }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

nonisolated extension Data {
    /// base64url, no padding — what PKCE and the rest of OAuth want everywhere.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
