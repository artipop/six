import Foundation

/// A list of MCP servers that are known to carry an **app**.
///
/// The official registry has no such list and cannot have one: nothing in its schema says whether a
/// server draws anything, so the only way to know is to connect and look for `_meta.ui.resourceUri`
/// in `tools/list`. Nobody publishes the answer, so six works it out and keeps it — a file, built by
/// sweeping the registry (`six --mcp-catalog`), shipped in the bundle, and refreshable in place.
///
/// It is a cache of an observation, not a curation: the sweep asks every remote server the registry
/// lists and writes down what answered. What it cannot ask it does not guess — a package server is
/// a download and a process, and the sweep will not run somebody's code to find out what it does.
nonisolated struct MCPCatalog: Codable, Sendable {
    /// When the sweep ran. An entry is a fact about a server on a day, not a promise about today.
    var generated: Date
    var source: String
    var entries: [Entry]

    struct Entry: Codable, Sendable, Identifiable, Hashable {
        /// The name that prefixes this server's tools for the agent.
        var id: String
        var name: String
        var description: String
        /// The registry namespace, which is the provenance the registry actually verifies.
        var namespace: String
        var url: URL
        var websiteURL: URL?
        /// How many tools the server has, and how many of them draw a window.
        var tools: Int
        var apps: Int
        /// The tools that carry an interface, by name — what to open first.
        var appTools: [String]

        var definition: MCPServerDefinition {
            MCPServerDefinition(id: id, name: name, url: url)
        }
    }

    static let empty = MCPCatalog(generated: .distantPast, source: "", entries: [])

    /// The copy that ships with six.
    static let bundled: MCPCatalog = {
        guard let url = Bundle.main.url(forResource: "MCPAppCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return (try? decoder.decode(MCPCatalog.self, from: data)) ?? .empty
    }()

    /// The copy a sweep wrote here, which wins over the bundled one when it is newer.
    static var savedURL: URL { AppSupport.file("MCPAppCatalog.json") }

    static var current: MCPCatalog {
        guard let data = try? Data(contentsOf: savedURL),
              let saved = try? decoder.decode(MCPCatalog.self, from: data),
              saved.generated > bundled.generated else { return bundled }
        return saved
    }

    func save() throws {
        try Self.encoder.encode(self).write(to: Self.savedURL, options: .atomic)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    // MARK: Building one

    /// Sweeps the registry and asks every remote server it lists what it carries.
    ///
    /// Concurrent and deadlined, because most of them will not answer: a registry entry is a claim
    /// that a URL existed when somebody published it, and a good few are gone, moved, or waiting
    /// behind a sign-in. One that hangs must cost fifteen seconds, not the sweep.
    static func sweep(limit: Int, query: String = "", concurrency: Int = 8,
                      timeout: TimeInterval = 12,
                      report: @escaping @Sendable (String) -> Void) async throws -> MCPCatalog {
        let servers = try await MCPRegistry.all(limit: limit, search: query) { count in
            report("registry: \(count) servers")
        }
        let remote = servers.filter(\.isRemote)
        report("\(servers.count) servers, \(remote.count) of them remote; asking each")

        var found: [Entry] = []
        var asked = 0
        // Batches of independent `Task`s rather than a task group. Measured, not preferred: in the
        // command-line process that builds this file — no AppKit, no run loop, the main thread
        // parked on a semaphore — a `withTaskGroup` never scheduled a single child, while a plain
        // `Task` runs fine. Same concurrency, one less thing between the work and the pool.
        for batch in stride(from: 0, to: remote.count, by: concurrency) {
            let slice = remote[batch..<min(batch + concurrency, remote.count)]
            let running = slice.compactMap { server -> Task<Answer, Never>? in
                guard let definition = server.definition() else { return nil }
                return Task { await ask(server, definition, timeout: timeout) }
            }
            for task in running {
                note(await task.value, &found, &asked, remote.count, report)
            }
        }
        report("asked \(asked); \(found.count) carry an app")
        return MCPCatalog(generated: Date(), source: MCPRegistry.base.absoluteString,
                          entries: uniqued(found.sorted { $0.name.lowercased() < $1.name.lowercased() }))
    }

    /// Ids have to be unique: an id is what prefixes this server's tools for the agent, and two
    /// servers answering to the same prefix are two servers six cannot tell apart. The id comes from
    /// the last part of the registry name, which collides often enough — `catalog`, `mcp`, `server`
    /// — so a collision takes the publisher's namespace with it.
    private static func uniqued(_ entries: [Entry]) -> [Entry] {
        var taken = Set<String>()
        return entries.map { entry in
            var entry = entry
            if !taken.insert(entry.id).inserted {
                let suffix = (entry.namespace.split(separator: ".").last.map(String.init) ?? "server").lowercased()
                var candidate = "\(entry.id)-\(suffix)"
                var n = 2
                while !taken.insert(candidate).inserted {
                    candidate = "\(entry.id)-\(suffix)-\(n)"
                    n += 1
                }
                entry.id = candidate
            }
            return entry
        }
    }

    /// What one server had to say — kept even when it is nothing, so the sweep can be watched.
    private struct Answer: Sendable {
        var name: String
        var entry: Entry?
        var note: String
    }

    private static func note(_ answer: Answer, _ found: inout [Entry], _ asked: inout Int,
                             _ total: Int, _ report: (String) -> Void) {
        asked += 1
        if let entry = answer.entry { found.append(entry) }
        report("  [\(asked)/\(total)] \(answer.name) — \(answer.note)")
    }

    /// One server. A `nil` entry means it answered nothing, refused, or had no interface to show.
    private static func ask(_ server: MCPRegistry.Entry, _ definition: MCPServerDefinition,
                            timeout: TimeInterval) async -> Answer {
        // The bound that actually holds is the session's; the deadline outside it is a second line
        // of defence, not the first.
        let client = MCPClient(definition: definition, timeout: timeout)
        defer { client.closeDetached() }
        let tools: [MCPTool]
        do {
            try await client.connect()
            tools = try await client.listTools()
        } catch {
            let message = error.localizedDescription
            let note = message.contains("401") || message.lowercased().contains("authoriz")
                ? "sign-in required"
                : String(message.prefix(60))
            return Answer(name: server.name, entry: nil, note: note)
        }
        let apps = tools.filter(\.hasApp)
        guard !apps.isEmpty, let url = definition.url else {
            return Answer(name: server.name, entry: nil, note: "\(tools.count) tools, no interface")
        }
        return Answer(name: server.name, entry: Entry(
            id: definition.id,
            name: server.display,
            description: server.description,
            namespace: server.namespace,
            url: url,
            websiteURL: server.websiteURL,
            tools: tools.count,
            apps: apps.count,
            appTools: apps.map(\.name)
        ), note: "▣ \(apps.count) of \(tools.count) draw a window")
    }
}
