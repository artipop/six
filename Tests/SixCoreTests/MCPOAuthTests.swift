// `MCPOAuth` itself is behind `#if canImport(CryptoKit)` — PKCE needs a SHA-256 and the Keychain,
// both of which are Apple's — so its tests have to be too, or the whole suite stops compiling on
// Linux and `scripts/six-linux.sh test` has nothing to run.
#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing

@testable import SixCore

/// The parts of OAuth that are string handling rather than network.
///
/// Which is most of what goes wrong. A `WWW-Authenticate` header is written by a server six has
/// never seen, in a grammar with two ways to quote; a `resource` parameter that is off by a trailing
/// slash is a token bound to something else; and an authorization endpoint reached over plaintext is
/// a token handed to whoever is on the wire. Each of those is one line of code and none of them
/// fails visibly. The round trip against a real authorization server is
/// [Tests/Servers](../Servers/README.md) with `--persona oauth`.
struct MCPOAuthTests {

    // MARK: The challenge

    @Test func readsTheResourceMetadataURLOutOfAChallenge() {
        let quoted = #"Bearer realm="mcp", resource_metadata="https://example.com/.well-known/oauth-protected-resource""#
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: quoted)
                == URL(string: "https://example.com/.well-known/oauth-protected-resource"))

        // Unquoted, with a parameter after it — the header grammar allows it and servers write it.
        let bare = "Bearer resource_metadata=https://example.com/prm, error=\"invalid_token\""
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: bare) == URL(string: "https://example.com/prm"))

        // Unquoted and last.
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: "Bearer resource_metadata=https://example.com/prm")
                == URL(string: "https://example.com/prm"))
    }

    @Test func aChallengeWithoutOneIsNil() {
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: nil) == nil)
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: "Bearer realm=\"mcp\"") == nil)
        #expect(MCPOAuth.resourceMetadataURL(fromChallenge: "Basic") == nil)
    }

    // MARK: Where six is willing to go

    /// OAuth 2.1 says HTTPS. Loopback is the one exception, and it is the exception the whole
    /// redirect flow is built on, so both halves are pinned.
    @Test func onlyHTTPSAndLoopbackAreSafeEndpoints() {
        #expect(MCPOAuth.isSafeEndpoint(URL(string: "https://example.com/token")!))
        #expect(MCPOAuth.isSafeEndpoint(URL(string: "http://localhost:7777/callback")!))
        #expect(MCPOAuth.isSafeEndpoint(URL(string: "http://127.0.0.1:7777/callback")!))

        #expect(!MCPOAuth.isSafeEndpoint(URL(string: "http://example.com/token")!))
        // Not loopback, however much it looks like it.
        #expect(!MCPOAuth.isSafeEndpoint(URL(string: "http://localhost.example.com/token")!))
        #expect(!MCPOAuth.isSafeEndpoint(URL(string: "http://127.0.0.1.example.com/token")!))
        #expect(!MCPOAuth.isSafeEndpoint(URL(string: "ftp://example.com/token")!))
    }

    // MARK: The resource parameter

    /// RFC 8707's canonical form. This string is what binds a token to one server, and both ends
    /// have to spell it the same way or the server rejects a token six believes is good.
    @Test func canonicalisesTheResourceURI() {
        func canonical(_ text: String) -> String { MCPOAuth.canonicalResource(URL(string: text)!) }

        #expect(canonical("https://example.com/mcp") == "https://example.com/mcp")
        #expect(canonical("https://example.com/mcp/") == "https://example.com/mcp")
        #expect(canonical("HTTPS://Example.COM/mcp") == "https://example.com/mcp")
        #expect(canonical("https://example.com/mcp#section") == "https://example.com/mcp")
        // A query is part of the identity and stays; only the fragment is dropped.
        #expect(canonical("https://example.com/mcp?v=2") == "https://example.com/mcp?v=2")
    }

    // MARK: The authorization request

    @Test func buildsAnAuthorizationURLWithEverythingTheSpecRequires() throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ServerMetadata.self, from: Data("""
        {
          "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize?tenant=six",
          "token_endpoint": "https://auth.example.com/token"
        }
        """.utf8))
        let pkce = MCPOAuth.PKCE()
        let url = try #require(MCPOAuth.authorizationURL(
            metadata: metadata, clientID: "client-1", redirectURI: "http://127.0.0.1:7777/callback",
            resource: "https://example.com/mcp", scope: "read write", pkce: pkce))

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("response_type") == "code")
        #expect(value("client_id") == "client-1")
        #expect(value("redirect_uri") == "http://127.0.0.1:7777/callback")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("state") == pkce.state)
        #expect(value("resource") == "https://example.com/mcp")
        #expect(value("scope") == "read write")
        // A query the endpoint already carried is kept rather than overwritten.
        #expect(value("tenant") == "six")
    }

    @Test func refusesToSendAnAuthorizationRequestOverPlaintext() throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ServerMetadata.self, from: Data("""
        { "authorization_endpoint": "http://auth.example.com/authorize",
          "token_endpoint": "http://auth.example.com/token" }
        """.utf8))
        #expect(MCPOAuth.authorizationURL(metadata: metadata, clientID: "c", redirectURI: "http://127.0.0.1:1/cb",
                                          resource: "https://example.com/mcp", scope: nil,
                                          pkce: MCPOAuth.PKCE()) == nil)
    }

    @Test func omitsAnEmptyScopeRatherThanSendingOne() throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ServerMetadata.self, from: Data("""
        { "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token" }
        """.utf8))
        for scope in [nil, ""] as [String?] {
            let url = try #require(MCPOAuth.authorizationURL(
                metadata: metadata, clientID: "c", redirectURI: "http://127.0.0.1:1/cb",
                resource: "https://example.com/mcp", scope: scope, pkce: MCPOAuth.PKCE()))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(!items.contains { $0.name == "scope" })
        }
    }

    // MARK: PKCE

    /// S256 over the verifier, base64url with no padding. Checked against RFC 7636's own worked
    /// example so the arithmetic is pinned to something outside this repository.
    @Test func theChallengeIsTheRFCsWorkedExample() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func everyPKCEIsItsOwn() {
        let a = MCPOAuth.PKCE(), b = MCPOAuth.PKCE()
        #expect(a.verifier != b.verifier)
        #expect(a.state != b.state)
        #expect(a.challenge != b.challenge)
        // base64url: no padding, and none of the three characters that would have to be escaped in
        // a query.
        for text in [a.verifier, a.challenge, a.state] {
            #expect(!text.contains("="))
            #expect(!text.contains("+"))
            #expect(!text.contains("/"))
            #expect(!text.isEmpty)
        }
    }

    @Test func base64URLDropsThePadding() {
        #expect(Data([0xFB, 0xFF]).base64URLEncoded == "-_8")
        #expect(Data([0x00]).base64URLEncoded == "AA")
        #expect(Data().base64URLEncoded == "")
    }

    // MARK: What is kept between runs

    /// A token that expires in twenty seconds is a token that will expire in the middle of the next
    /// request, so it counts as expired now.
    @Test func aTokenAboutToExpireCountsAsExpired() {
        func grant(_ expiresAt: Date?) -> MCPOAuth.Grant {
            MCPOAuth.Grant(issuer: "https://auth.example.com", clientID: "c",
                           redirectURI: "http://127.0.0.1:7777/callback", expiresAt: expiresAt)
        }
        #expect(grant(nil).isExpired == false)
        #expect(grant(Date().addingTimeInterval(600)).isExpired == false)
        #expect(grant(Date().addingTimeInterval(20)).isExpired == true)
        #expect(grant(Date().addingTimeInterval(-1)).isExpired == true)
    }

    /// The loopback port has to come back the same next launch, or the registered redirect URI no
    /// longer matches and the authorization server refuses the request.
    @Test func theGrantRemembersItsLoopbackPort() {
        let grant = MCPOAuth.Grant(issuer: "i", clientID: "c", redirectURI: "http://127.0.0.1:52411/callback")
        #expect(grant.port == 52411)
        #expect(MCPOAuth.Grant(issuer: "i", clientID: "c", redirectURI: "not a url").port == 0)
    }

    @Test func aGrantSurvivesTheKeychainRoundTrip() throws {
        let original = MCPOAuth.Grant(issuer: "https://auth.example.com", clientID: "c", clientSecret: nil,
                                      redirectURI: "http://127.0.0.1:7777/callback",
                                      accessToken: "at", refreshToken: "rt",
                                      expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scope: "read")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(MCPOAuth.Grant.self, from: data)
        #expect(restored.accessToken == "at")
        #expect(restored.refreshToken == "rt")
        #expect(restored.scope == "read")
        #expect(restored.expiresAt == original.expiresAt)
    }

    // MARK: Metadata

    @Test func readsProtectedResourceMetadata() throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ResourceMetadata.self, from: Data("""
        {
          "resource": "https://example.com/mcp",
          "authorization_servers": ["https://auth.example.com"],
          "scopes_supported": ["read", "write"]
        }
        """.utf8))
        #expect(metadata.resource == "https://example.com/mcp")
        #expect(metadata.authorizationServers == [URL(string: "https://auth.example.com")!])
        #expect(metadata.scopesSupported == ["read", "write"])
    }

    /// An authorization server that offers no registration endpoint is one six cannot use, and the
    /// decoder has to survive its metadata rather than throw on the missing field.
    @Test func serverMetadataToleratesEverythingOptional() throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ServerMetadata.self, from: Data("""
        { "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token" }
        """.utf8))
        #expect(metadata.registrationEndpoint == nil)
        #expect(metadata.issuer == nil)
        #expect(metadata.scopesSupported == nil)
    }

    @Test func registrationIsRefusedWithoutAnEndpoint() async throws {
        let metadata = try JSONDecoder().decode(MCPOAuth.ServerMetadata.self, from: Data("""
        { "issuer": "https://auth.example.com",
          "authorization_endpoint": "https://auth.example.com/authorize",
          "token_endpoint": "https://auth.example.com/token" }
        """.utf8))
        await #expect(throws: MCPOAuth.Failure.self) {
            _ = try await MCPOAuth.register(with: metadata, redirectURI: "http://127.0.0.1:1/cb")
        }
    }
}
#endif
