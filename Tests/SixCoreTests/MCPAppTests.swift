import Foundation
import Testing

@testable import SixCore

/// What six reads out of an MCP server's answers, and the policy it writes back.
///
/// Everything here is a pure function of JSON that came off a wire six does not control, which is
/// exactly the part worth pinning down: a server can send any of this, in either of two spellings,
/// or none of it, and the difference between "app-only tool" and "tool the agent may call" is one
/// missing array away. The live half — the session, the scheme handler, the window — is checked by
/// running the servers in [Tests/Servers](../Servers/README.md).
struct MCPAppTests {

    private func json(_ text: String) -> ACPJSON {
        try! JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8))
    }

    // MARK: Tools

    @Test func readsTheNestedExtensionMetadata() {
        let tool = MCPTool(json: json("""
        {
          "name": "show_map",
          "title": "Show a map",
          "description": "Draws a place.",
          "inputSchema": { "type": "object", "properties": { "place": { "type": "string" } } },
          "annotations": { "readOnlyHint": true },
          "_meta": { "ui": { "resourceUri": "ui://map/main", "visibility": ["model", "app"] } }
        }
        """))
        #expect(tool.name == "show_map")
        #expect(tool.display == "Show a map")
        #expect(tool.uiResourceURI == "ui://map/main")
        #expect(tool.hasApp)
        #expect(tool.isReadOnly)
        #expect(tool.visibility == [.model, .app])
        #expect(tool.inputSchema?["type"]?.stringValue == "object")
    }

    /// The flat spelling is deprecated and still on the wire; the nested one wins when a server
    /// sends both, which live servers do.
    @Test func readsTheDeprecatedFlatResourceURI() {
        let flat = MCPTool(json: json("""
        { "name": "t", "_meta": { "ui/resourceUri": "ui://old/main" } }
        """))
        #expect(flat.uiResourceURI == "ui://old/main")

        let both = MCPTool(json: json("""
        { "name": "t", "_meta": { "ui/resourceUri": "ui://old/main", "ui": { "resourceUri": "ui://new/main" } } }
        """))
        #expect(both.uiResourceURI == "ui://new/main")
    }

    /// No `visibility` means both. This is the default that decides whether an agent is even told a
    /// tool exists, so it is worth a test that fails if somebody flips the sense of the `if`.
    @Test func visibilityDefaultsToBothAndNarrowsWhenDeclared() {
        #expect(MCPTool(json: json(#"{ "name": "t" }"#)).visibility == [.model, .app])
        #expect(MCPTool(json: json(#"{ "name": "t", "_meta": { "ui": {} } }"#)).visibility == [.model, .app])

        let appOnly = MCPTool(json: json(#"{ "name": "t", "_meta": { "ui": { "visibility": ["app"] } } }"#))
        #expect(appOnly.visibility == [.app])
        #expect(!appOnly.visibility.contains(.model))

        // A word six does not know is dropped rather than taken for something. An empty set is a
        // tool nobody may call, which is what a server asking for "nobody" should get.
        let strange = MCPTool(json: json(#"{ "name": "t", "_meta": { "ui": { "visibility": ["operator"] } } }"#))
        #expect(strange.visibility.isEmpty)
    }

    @Test func aToolWithoutMetadataIsNotAnApp() {
        let tool = MCPTool(json: json(#"{ "name": "add", "description": "Adds." }"#))
        #expect(!tool.hasApp)
        #expect(!tool.isReadOnly)
        #expect(tool.display == "add")
    }

    // MARK: Resources

    @Test func readsAUIResourceAndItsMetadata() {
        let resource = MCPUIResource(contents: json("""
        {
          "uri": "ui://map/main",
          "mimeType": "text/html;profile=mcp-app",
          "text": "<!doctype html><p>hi",
          "_meta": { "ui": {
            "domain": "map.example.com",
            "prefersBorder": true,
            "csp": { "connectDomains": ["https://api.example.com"], "resourceDomains": ["https://cdn.example.com"] },
            "permissions": { "geolocation": {} }
          } }
        }
        """))
        #expect(resource?.uri == "ui://map/main")
        #expect(resource?.isApp == true)
        #expect(resource?.domain == "map.example.com")
        #expect(resource?.prefersBorder == true)
        #expect(resource?.permissions.geolocation == true)
        #expect(resource?.permissions.camera == false)
        #expect(resource?.permissions.isEmpty == false)
        #expect(resource?.csp.connectDomains == ["https://api.example.com"])
    }

    /// `blob` is the other half of `resources/read`, and a server that sends base64 is sending the
    /// same document.
    @Test func readsAResourceSentAsBase64() {
        let html = "<!doctype html><title>b</title>"
        let resource = MCPUIResource(contents: json("""
        { "uri": "ui://b/main", "mimeType": "text/html;profile=mcp-app",
          "blob": "\(Data(html.utf8).base64EncodedString())" }
        """))
        #expect(resource?.html == html)
    }

    @Test func refusesContentsThatAreNeitherTextNorBlob() {
        #expect(MCPUIResource(contents: json(#"{ "uri": "ui://x/main" }"#)) == nil)
        #expect(MCPUIResource(contents: json(#"{ "text": "<p>no uri" }"#)) == nil)
    }

    /// `isApp` is the gate `MCPClient.readUIResource` refuses on. HTML that is not declared with the
    /// profile is somebody's web page, not an app, and rendering it under the app's privileges would
    /// be the whole security model going out of the window.
    @Test func onlyTheProfiledMimeTypeIsAnApp() {
        func isApp(_ mime: String) -> Bool {
            MCPUIResource(contents: json(#"{ "uri": "ui://x/main", "mimeType": "\#(mime)", "text": "<p>" }"#))?.isApp == true
        }
        #expect(isApp("text/html;profile=mcp-app"))
        #expect(isApp("text/html; profile=mcp-app; charset=utf-8"))
        #expect(!isApp("text/html"))
        #expect(!isApp("text/plain"))
        #expect(!isApp("application/json"))
    }

    // MARK: The policy

    /// The floor, for an app that declared nothing. Written out in full on purpose: this string is
    /// the security model, and every loosening of it should have to be typed here first.
    @Test func theDefaultPolicyIsTheSpecificationsOwn() {
        let policy = MCPUIResource.CSP().header
        #expect(policy == "default-src 'none'; "
                + "script-src 'self' 'unsafe-inline'; "
                + "style-src 'self' 'unsafe-inline'; "
                + "img-src 'self' data:; "
                + "media-src 'self' data:; "
                + "object-src 'none'; "
                + "connect-src 'none'; "
                + "frame-src 'none'; "
                + "base-uri 'self'")
    }

    /// A declared domain widens exactly the directive the extension maps it to, and nothing else.
    @Test func declaredDomainsWidenOnlyTheirOwnDirective() {
        var csp = MCPUIResource.CSP()
        csp.connectDomains = ["https://api.example.com"]
        csp.resourceDomains = ["https://cdn.example.com"]
        csp.frameDomains = ["https://embed.example.com"]
        csp.baseUriDomains = ["https://example.com"]
        let policy = csp.header

        #expect(policy.contains("script-src 'self' 'unsafe-inline' https://cdn.example.com"))
        #expect(policy.contains("style-src 'self' 'unsafe-inline' https://cdn.example.com"))
        #expect(policy.contains("img-src 'self' data: https://cdn.example.com"))
        #expect(policy.contains("media-src 'self' data: https://cdn.example.com"))
        #expect(policy.contains("font-src 'self' https://cdn.example.com"))
        #expect(policy.contains("connect-src https://api.example.com"))
        #expect(policy.contains("frame-src https://embed.example.com"))
        #expect(policy.contains("base-uri https://example.com"))
        // `connect-src` never picks up a resource domain, and the reverse.
        #expect(!policy.contains("connect-src https://cdn"))
        #expect(!policy.contains("img-src 'self' data: https://api"))
    }

    /// There is no field in `ui.csp` for `'unsafe-eval'`, `blob:` or `worker-src`, so no server can
    /// ask for them and six emits none of them. This is what stops an app from evaluating strings it
    /// was handed, and it is the reason CesiumJS does not run in six — see the note on `CSP.header`.
    @Test func nothingAnAppCanDeclareBringsBackEval() {
        var csp = MCPUIResource.CSP()
        csp.connectDomains = ["'unsafe-eval'", "blob:", "*"]
        csp.resourceDomains = ["'unsafe-eval'"]
        let policy = csp.header
        #expect(!policy.contains("unsafe-eval"))
        #expect(!policy.contains("worker-src"))
        #expect(policy.contains("script-src 'self' 'unsafe-inline';"))
        // `blob:` is a scheme source and passes the shape test, so it lands where it was declared
        // and nowhere else. `*` on its own does not.
        #expect(policy.contains("connect-src blob:"))
        #expect(!policy.contains("connect-src blob: *"))
    }

    /// A declared domain is not data, it is policy: it is joined into a header with spaces and
    /// semicolons around it. A server that writes a `;` into one is writing a second directive, and
    /// this is the test that says it does not get to.
    @Test func aDeclaredDomainCannotSmuggleASecondDirective() {
        let resource = MCPUIResource(contents: json("""
        { "uri": "ui://x/main", "mimeType": "text/html;profile=mcp-app", "text": "<p>",
          "_meta": { "ui": { "csp": { "connectDomains": [
            "https://evil.example.com; script-src *",
            "https://ok.example.com",
            "https://a.example.com wss://b.example.com",
            "'unsafe-inline'",
            "https://c.example.com\\ndefault-src *"
          ] } } } }
        """))
        #expect(resource?.csp.connectDomains == ["https://ok.example.com"])
        let policy = try! #require(resource).csp.header
        #expect(policy.contains("connect-src https://ok.example.com"))
        #expect(!policy.contains("script-src *"))
        #expect(!policy.contains("default-src *"))
        #expect(policy.hasPrefix("default-src 'none'; script-src 'self' 'unsafe-inline';"))
    }

    @Test func aPlausibleSourceIsAnOriginAndNothingElse() {
        for good in ["https://example.com", "https://*.example.com", "wss://example.com:8443",
                     "example.com", "blob:", "data:", "https://example.com/path"] {
            #expect(MCPUIResource.CSP.isPlausibleSource(good), "\(good) should be allowed")
        }
        for bad in ["", "*", "'self'", "'unsafe-eval'", "https://a; script-src *", "https://a b",
                    "https://a\n", "https://a\tb", "https://a,https://b", "<script>",
                    String(repeating: "a", count: 513)] {
            #expect(!MCPUIResource.CSP.isPlausibleSource(bad), "\(bad) should be refused")
        }
    }

    @Test func aResourceWithoutMetadataGetsTheClosedDoor() {
        let resource = MCPUIResource(contents: json("""
        { "uri": "ui://x/main", "mimeType": "text/html;profile=mcp-app", "text": "<p>" }
        """))
        #expect(resource?.csp.connectDomains.isEmpty == true)
        #expect(resource?.permissions.isEmpty == true)
        #expect(resource?.header(contains: "connect-src 'none'") == true)
    }

    // MARK: Servers

    /// `shellCommandLine` is shown, never run — but it is shown to somebody deciding whether to let
    /// six launch it, so it has to read as what a shell would actually do.
    @Test func aCommandLineIsQuotedTheWayAShellWouldReadIt() {
        let plain = MCPServerDefinition(id: "s", command: "npx", arguments: ["-y", "@scope/server-map", "--stdio"])
        #expect(plain.shellCommandLine == "npx -y @scope/server-map --stdio")

        let awkward = MCPServerDefinition(id: "s", command: "python3",
                                          arguments: ["/tmp/my server.py", "--flag=a b", "it's"])
        #expect(awkward.shellCommandLine == #"python3 '/tmp/my server.py' '--flag=a b' 'it'\''s'"#)
    }

    @Test func aServerIsRemoteExactlyWhenItHasAURL() {
        let remote = MCPServerDefinition(id: "s", url: URL(string: "https://example.com/mcp")!)
        #expect(remote.isRemote)
        #expect(remote.location == "https://example.com/mcp")

        let local = MCPServerDefinition(id: "s", command: "npx", arguments: ["-y", "thing"])
        #expect(!local.isRemote)
        #expect(local.location == "npx -y thing")
    }

    @Test func aServerSurvivesBeingWrittenDownAndReadBack() throws {
        let original = MCPServerDefinition(id: "weather", name: "Weather",
                                           url: URL(string: "https://example.com/mcp")!,
                                           headers: ["X-Key": "secret"])
        let restored = try JSONDecoder().decode(MCPServerDefinition.self,
                                                from: JSONEncoder().encode(original))
        #expect(restored == original)
    }
}

private extension MCPUIResource {
    func header(contains fragment: String) -> Bool { csp.header.contains(fragment) }
}
