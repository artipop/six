import Foundation
import Testing

@testable import SixCore

/// Turning a registry listing into something six can actually open.
///
/// The registry describes servers for every client there is, most of which six cannot run: an `sse`
/// endpoint on a transport MCP replaced, a Docker image, a `.mcpb` bundle, a command line with
/// `<your-api-key>` left in it for a human to fill. Offering any of those from a search field is a
/// promise six cannot keep, so the mapping is deliberately narrow and this is where that narrowness
/// is written down.
struct MCPRegistryTests {

    private func parse(_ text: String) -> MCPRegistry.Entry? {
        MCPRegistry.entry(from: try! JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8)))
    }

    @Test func readsARemoteServer() throws {
        let entry = try #require(parse("""
        {
          "name": "io.github.someone/weather",
          "title": "Weather",
          "description": "Forecasts.",
          "version": "1.2.0",
          "websiteUrl": "https://weather.example.com",
          "repository": { "url": "https://github.com/someone/weather" },
          "remotes": [{ "type": "streamable-http", "url": "https://weather.example.com/mcp" }]
        }
        """))
        #expect(entry.display == "Weather")
        #expect(entry.namespace == "io.github.someone")
        #expect(entry.version == "1.2.0")
        #expect(entry.repositoryURL == URL(string: "https://github.com/someone/weather"))
        #expect(entry.remotes == [URL(string: "https://weather.example.com/mcp")!])
        #expect(entry.isRemote)
    }

    /// `sse` is the transport MCP replaced. Listing a server six cannot open would be worse than
    /// not listing it.
    @Test func ignoresEveryTransportButStreamableHTTP() throws {
        let entry = try #require(parse("""
        { "name": "a/b", "remotes": [
            { "type": "sse", "url": "https://example.com/sse" },
            { "type": "streamable-http", "url": "https://example.com/mcp" }
        ] }
        """))
        #expect(entry.remotes == [URL(string: "https://example.com/mcp")!])
    }

    @Test func buildsACommandLineForNPMAndPyPI() throws {
        let npm = try #require(parse("""
        { "name": "a/b", "packages": [
            { "registryType": "npm", "identifier": "@scope/server-map", "version": "0.4.1" }
        ] }
        """))
        #expect(npm.package?.command == "npx")
        #expect(npm.package?.arguments == ["-y", "@scope/server-map@0.4.1"])

        let pypi = try #require(parse("""
        { "name": "a/b", "packages": [{ "registryType": "pypi", "identifier": "mcp-map", "version": "2.0" }] }
        """))
        #expect(pypi.package?.command == "uvx")
        #expect(pypi.package?.arguments == ["mcp-map==2.0"])
    }

    /// A Docker image or an OCI bundle is somebody's install step. `package` stays nil, and with no
    /// remote either the entry is one six will not offer to open.
    @Test func refusesPackagesSixCannotLaunch() throws {
        let docker = try #require(parse("""
        { "name": "a/b", "packages": [{ "registryType": "oci", "identifier": "ghcr.io/someone/server" }] }
        """))
        #expect(docker.package == nil)
        #expect(docker.definition() == nil)
    }

    /// A placeholder the publisher left for a person to fill in is dropped rather than passed
    /// along: a server launched with a literal `<your-api-key>` fails in a way nobody can read.
    @Test func dropsPlaceholderArguments() throws {
        let entry = try #require(parse("""
        { "name": "a/b", "packages": [{
            "registryType": "npm", "identifier": "server", "packageArguments": [
              { "type": "positional", "value": "--stdio" },
              { "type": "positional", "value": "<your-api-key>" },
              { "type": "named", "name": "--key", "value": "<paste here>", "isRequired": true },
              { "type": "named", "name": "--verbose" },
              { "type": "named", "name": "--region", "value": "eu" }
            ]
        }] }
        """))
        #expect(entry.package?.arguments == ["-y", "server", "--stdio", "--verbose", "--region", "eu"])
    }

    /// Remote first: a URL costs a POST, a package costs a download and a process.
    @Test func prefersARemoteEndpointOverAPackage() throws {
        let entry = try #require(parse("""
        { "name": "io.github.someone/weather-forecast",
          "remotes": [{ "type": "streamable-http", "url": "https://example.com/mcp" }],
          "packages": [{ "registryType": "npm", "identifier": "weather" }] }
        """))
        #expect(entry.definition()?.isRemote == true)
        #expect(entry.definition(preferringRemote: false)?.command == "npx")
        // Falls back to the remote when there is no package, whichever way it was asked.
        let remoteOnly = try #require(parse("""
        { "name": "a/b", "remotes": [{ "type": "streamable-http", "url": "https://example.com/mcp" }] }
        """))
        #expect(remoteOnly.definition(preferringRemote: false)?.isRemote == true)
    }

    /// The id prefixes this server's tools for the agent, so it has to be a plain word — the last
    /// path component of a registry name, with everything a tool name cannot carry folded out.
    @Test func theIDIsTheLastPathComponentMadeIntoAWord() throws {
        func id(_ name: String) -> String? {
            parse(#"{ "name": "\#(name)", "remotes": [{ "type": "streamable-http", "url": "https://e.com/mcp" }] }"#)?
                .definition()?.id
        }
        #expect(id("io.github.someone/weather") == "weather")
        #expect(id("ai.smithery/Map Server") == "map-server")
        #expect(id("io.github.someone/weather_forecast.v2") == "weather-forecast-v2")
        #expect(id("plain") == "plain")
    }

    @Test func anEntryWithoutANameIsNotAnEntry() {
        #expect(parse(#"{ "description": "no name" }"#) == nil)
        #expect(parse(#"{ "name": "" }"#) == nil)
    }

    /// Nothing in the registry says whether a server carries an interface, which is the whole reason
    /// `MCPAppStore.probe` has to connect and look. If a field for it ever appears, this test is the
    /// place that should start failing to notice.
    @Test func theRegistrySaysNothingAboutInterfaces() throws {
        let entry = try #require(parse("""
        { "name": "a/b", "remotes": [{ "type": "streamable-http", "url": "https://e.com/mcp" }] }
        """))
        let mirror = Mirror(reflecting: entry)
        let fields = mirror.children.compactMap(\.label)
        #expect(!fields.contains { $0.lowercased().contains("ui") || $0.lowercased().contains("app") })
    }
}
