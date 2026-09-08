import Foundation
import Observation

/// Where a remote server's tokens live: the Keychain, not the settings table.
///
/// Everything else six keeps is a preference — a search engine, a list of hosts. An OAuth refresh
/// token is a credential: anything that can read it can act as the user against that server for as
/// long as it lives. The settings database is a file in Application Support, readable by anything
/// running as the user; the Keychain is the one place on the Mac that is not.
nonisolated enum MCPTokenStore {
    private static let service = "org.deffun.six.mcp"

    static func load(_ serverID: String) -> MCPOAuth.Grant? {
        var query = base(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MCPOAuth.Grant.self, from: data)
    }

    static func save(_ grant: MCPOAuth.Grant, for serverID: String) {
        guard let data = try? JSONEncoder().encode(grant) else { return }
        let query = base(serverID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess { return }
        var insert = query
        insert[kSecValueData as String] = data
        // The tokens are this Mac's; a sync would put a credential six cannot revoke on machines
        // six was never asked about.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func forget(_ serverID: String) {
        SecItemDelete(base(serverID) as CFDictionary)
    }

    /// The secret half of a client somebody typed in (`MCPOAuthClient`). It is a credential like the
    /// tokens, and lives beside them rather than in the settings table with the id — an id that
    /// leaks is a nuisance, a secret that leaks is somebody else's application talking to the
    /// provider as six.
    static func clientSecret(_ serverID: String) -> String? {
        var query = base(serverID, kind: .clientSecret)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// An empty secret is a deletion: a provider that wants none should leave nothing behind.
    static func setClientSecret(_ secret: String, for serverID: String) {
        let query = base(serverID, kind: .clientSecret)
        guard !secret.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(secret.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func forgetClientSecret(_ serverID: String) {
        SecItemDelete(base(serverID, kind: .clientSecret) as CFDictionary)
    }

    /// Two items per server at most, told apart by the account name.
    private enum Kind: String {
        case token = ""
        case clientSecret = "#oauth-client"
    }

    private static func base(_ serverID: String, kind: Kind = .token) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID + kind.rawValue,
        ]
    }
}

/// The interactive half of OAuth: the part that needs a browser and a person.
///
/// `MCPOAuth` knows the protocol and touches no state; this knows which server is being signed in
/// to, where the token is kept, and — because six *is* the browser — opens the authorization page
/// as a window of the strip rather than handing it to somebody else's.
@MainActor
@Observable
final class MCPAuthorization {
    /// Servers with a token in hand, for the panel to mark.
    private(set) var signedIn: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private var grants: [String: MCPOAuth.Grant] = [:]
    /// One sign-in at a time per server: two requests answering 401 at once must not open two
    /// authorization windows for the same thing.
    @ObservationIgnored private var running: [String: Task<String, Error>] = [:]

    /// How long a half-finished sign-in is left waiting before the window is given up on.
    static let patience: Duration = .seconds(300)

    func grant(for serverID: String) -> MCPOAuth.Grant? {
        if let cached = grants[serverID] { return cached }
        guard let stored = MCPTokenStore.load(serverID) else { return nil }
        grants[serverID] = stored
        signedIn.insert(serverID)
        return stored
    }

    /// The token to send with the next request, when there is one that has not expired.
    func token(for server: MCPServerDefinition) -> String? {
        guard let grant = grant(for: server.id), !grant.isExpired else { return nil }
        return grant.accessToken
    }

    func signOut(_ server: MCPServerDefinition) {
        running[server.id]?.cancel()
        running[server.id] = nil
        grants[server.id] = nil
        signedIn.remove(server.id)
        MCPTokenStore.forget(server.id)
    }

    /// A request came back 401. Refresh if that is enough; otherwise sign in.
    func authorize(_ server: MCPServerDefinition, challenge: String?) async -> String? {
        guard let url = server.url else { return nil }
        if let existing = running[server.id] { return try? await existing.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw MCPOAuth.Failure.denied("six is going away") }
            defer { self.running[server.id] = nil }
            return try await self.run(server: server, endpoint: url, challenge: challenge)
        }
        running[server.id] = task
        do {
            let token = try await task.value
            lastError = nil
            return token
        } catch is CancellationError {
            return nil
        } catch {
            lastError = "\(server.name): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: The flow

    private func run(server: MCPServerDefinition, endpoint: URL, challenge: String?) async throws -> String {
        let resource = MCPOAuth.canonicalResource(endpoint)
        let resourceMetadata = await MCPOAuth.resourceMetadata(for: endpoint, challenge: challenge)
        // The server's own answer first; the configured issuer is the fallback for a provider that
        // publishes no protected-resource metadata at all.
        guard let issuer = resourceMetadata?.authorizationServers?.first ?? server.oauth?.issuer else {
            throw MCPOAuth.Failure.noAuthorizationServer(endpoint)
        }
        guard let metadata = await MCPOAuth.serverMetadata(for: issuer) else {
            throw MCPOAuth.Failure.noMetadata(issuer)
        }

        // The cheap way first: a refresh token six already holds costs nobody a click.
        if let existing = grant(for: server.id), existing.refreshToken != nil {
            if let refreshed = try? await MCPOAuth.refresh(existing, metadata: metadata, resource: resource),
               let token = refreshed.accessToken {
                store(refreshed, for: server.id)
                return token
            }
        }

        let loopback = MCPLoopback()
        // A client typed in by hand has its redirect URI registered with the provider letter for
        // letter, so its port is not a preference: coming back on another one is a sign-in that
        // fails at the last step, with an error from the provider rather than from six.
        try loopback.start(preferredPort: server.oauth?.redirectPort ?? grant(for: server.id)?.port ?? 0)
        defer { loopback.stop() }
        if let configured = server.oauth?.redirectPort, loopback.port != configured {
            throw MCPOAuth.Failure.portTaken(configured)
        }
        let redirectURI = loopback.redirectURI

        // A registration is only good for the redirect URI it was made with, so a port six could not
        // get back means registering again rather than a sign-in that fails at the last step.
        let previous = grant(for: server.id)
        let credentials: (id: String, secret: String?)
        if let client = server.oauth {
            credentials = (client.clientID, MCPTokenStore.clientSecret(server.id))
        } else if let previous, previous.issuer == (metadata.issuer ?? issuer.absoluteString), previous.redirectURI == redirectURI {
            credentials = (previous.clientID, previous.clientSecret)
        } else {
            credentials = try await MCPOAuth.register(with: metadata, redirectURI: redirectURI)
        }

        let pkce = MCPOAuth.PKCE()
        // What the person asked for wins: a provider that publishes no scopes anywhere is exactly
        // the kind that also has to be told which ones it is being asked for.
        let configuredScopes = server.oauth.map(\.scopes).flatMap { $0.isEmpty ? nil : $0.joined(separator: " ") }
        let scope = configuredScopes ?? (resourceMetadata?.scopesSupported ?? metadata.scopesSupported)?.joined(separator: " ")
        guard let authorizationURL = MCPOAuth.authorizationURL(
            metadata: metadata, clientID: credentials.id, redirectURI: redirectURI,
            resource: resource, scope: scope, pkce: pkce
        ) else { throw MCPOAuth.Failure.noMetadata(issuer) }

        // six opens it itself. A browser handing a sign-in page to another browser is the one thing
        // it never has to do — and the window stays in the strip, where the person can see what
        // they are signing in to.
        browser?.newTab(url: authorizationURL)

        let query = try await MCPApps.withDeadline(Self.patience) { try await loopback.waitForCallback() }
        if let error = query["error"] {
            throw MCPOAuth.Failure.denied(query["error_description"] ?? error)
        }
        guard query["state"] == pkce.state else { throw MCPOAuth.Failure.stateMismatch }
        guard let code = query["code"] else { throw MCPOAuth.Failure.denied("no code in the redirect") }

        let grant = try await MCPOAuth.exchange(
            code: code, metadata: metadata, clientID: credentials.id, clientSecret: credentials.secret,
            redirectURI: redirectURI, resource: resource, verifier: pkce.verifier
        )
        store(grant, for: server.id)
        guard let token = grant.accessToken else { throw MCPOAuth.Failure.denied("no access token") }
        return token
    }

    private func store(_ grant: MCPOAuth.Grant, for serverID: String) {
        grants[serverID] = grant
        signedIn.insert(serverID)
        MCPTokenStore.save(grant, for: serverID)
    }

}
