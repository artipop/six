import Foundation
import Observation

/// The servers six is host to, and the apps running from them.
///
/// One connection per server, kept for as long as the app is running: an app's own `tools/call`
/// goes back down the connection it was born on, so closing it would take the app's hands away.
@MainActor
@Observable
final class MCPAppStore {
    /// The servers six can reach. Only the ones somebody put here: the demos six is developed
    /// against are reached with `--mcp-probe example:<name>`, which is a developer's tool and not a
    /// list to ship in front of everyone (see [mcp-apps.md](../../../docs/mcp-apps.md)).
    var servers: [MCPServerDefinition] { customServers }

    /// The servers the user added, kept in the settings table with everything else — as JSON there,
    /// because that table is shared with a front end that has never heard of MCP.
    var customServers: [MCPServerDefinition] {
        get {
            guard let text = settings?.mcpCustomServers, !text.isEmpty,
                  let servers = try? JSONDecoder().decode([MCPServerDefinition].self, from: Data(text.utf8))
            else { return [] }
            return servers
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            settings?.mcpCustomServers = String(decoding: data, as: UTF8.self)
        }
    }

    func add(_ definition: MCPServerDefinition) {
        var current = customServers
        current.removeAll { $0.id == definition.id }
        current.append(definition)
        customServers = current
        // Editing a server that is already shared changes its tools too — a new URL is a new list.
        if isShared(definition) { onSharedServersChanged?() }
    }

    func remove(_ definition: MCPServerDefinition) {
        setShared(definition, false)
        authorization.signOut(definition)
        // The client somebody typed in goes with the server it was typed in for; leaving a secret
        // in the Keychain for a server nobody can see is how a credential outlives its purpose.
        MCPTokenStore.forgetClientSecret(definition.id)
        for session in sessions where session.server.id == definition.id {
            browser?.closeTab(session.id)
        }
        customServers.removeAll { $0.id == definition.id }
        disconnect(definition)
    }


    private(set) var lastError: String?
    /// What is running, newest last.
    private(set) var sessions: [MCPAppSession] = []

    /// Signing in to remote servers (`MCPAuthorization`). Owned here because a sign-in needs a
    /// window, and the store is what has the browser.
    let authorization = MCPAuthorization()

    /// Servers already known to carry an app — six's own list, because nobody publishes one
    /// (`MCPCatalog`). Read once at launch; a sweep writing a newer file is picked up by `reload`.
    private(set) var catalog = MCPCatalog.current

    func reloadCatalog() { catalog = .current }

    @ObservationIgnored weak var browser: BrowserState? {
        didSet { authorization.browser = browser }
    }
    #if os(macOS)
    /// The agent panel, for `ui/message` and `ui/update-model-context`. There is none on a phone.
    @ObservationIgnored weak var agent: AgentSessionStore?
    #endif
    /// Somebody to tell that what the agent would be given has changed — `MCPHost.toolsChanged`,
    /// set where the two halves are wired together. A closure rather than a reference back to the
    /// host: the store is what six is host *to*, and it has no business knowing about the socket.
    ///
    /// Not behind `#if os(macOS)` even though only the Mac sets it: `add` and `setShared` call it,
    /// and they are the same code on both platforms. Guarding the property and not its two call
    /// sites is what stopped the iOS target building.
    @ObservationIgnored var onSharedServersChanged: (() -> Void)?
    @ObservationIgnored weak var settings: SettingsStore?
    @ObservationIgnored private var clients: [MCPServerDefinition.ID: MCPClient] = [:]
    /// `ui://` documents already read, per server. A template is the static half of an app — the
    /// spec says as much, and says a host MAY cache it — so opening the same app twice reads it
    /// once. Dropped with the server's connection.
    @ObservationIgnored private var resources: [String: MCPUIResource] = [:]

    /// The separator between a server's name and a tool's in the name six hands the agent. Two
    /// underscores, because that is what an agent's own prefix uses and what `AgentToolName.display`
    /// turns back into a space: `mcp__six__map__show-map` is read out as *six map show-map* — six,
    /// the server it is host to, the tool. See [mcp.md](mcp.md#names).
    static let separator = "__"

    /// Watches for the Mac switching between light and dark, so running apps can be told.
    /// A distributed notification because that is the only one AppKit posts for the *system*
    /// appearance, rather than for a view of six's that happened to redraw.
    func watchAppearance() {
        #if os(macOS)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions { session.refreshTheme() }
            }
        }
        #endif
    }

    // MARK: Looking a server up

    /// What connecting to a server found. The registry cannot say whether a server carries an
    /// interface — no field of its schema does — so six connects and counts.
    enum Probe: Equatable, Sendable {
        case probing
        /// How many tools, and how many of them draw something.
        case answered(tools: Int, apps: Int)
        /// The server wants a sign-in before it says anything.
        case needsSignIn
        case failed(String)

        var appCount: Int? { if case .answered(_, let apps) = self { return apps }; return nil }
    }

    /// Keyed by where the server is, so the same endpoint probed from a search and from the list is
    /// the same answer.
    private(set) var probes: [String: Probe] = [:]

    /// What a previous probe found, if anything. Named apart from `probe(_:force:)` on purpose:
    /// two overloads differing only by an `async` and a defaulted argument is a trap, and Swift
    /// picks the wrong one.
    func probeResult(for definition: MCPServerDefinition) -> Probe? { probes[definition.location] }

    /// Connects, lists the tools, counts the ones with a `ui://` resource, and disconnects.
    ///
    /// Deliberately without `authorization`: a probe is six looking around, and looking around must
    /// never put a sign-in window in front of someone who only typed a search. A server that
    /// answers 401 is reported as wanting one, and asked properly when it is added.
    @discardableResult
    func probe(_ definition: MCPServerDefinition, force: Bool = false) async -> Probe {
        let key = definition.location
        if !force, let existing = probes[key], existing != .probing { return existing }
        probes[key] = .probing
        let client = MCPClient(definition: definition, timeout: 15)
        let result: Probe
        do {
            try await client.connect()
            let tools = try await client.listTools()
            result = .answered(tools: tools.count, apps: tools.filter(\.hasApp).count)
        } catch {
            let message = error.localizedDescription
            result = message.contains("401") || message.lowercased().contains("authorization")
                ? .needsSignIn
                : .failed(message)
        }
        await client.close()
        probes[key] = result
        return result
    }

    /// A server by the name a person would type: one that is already in the list, or one from the
    /// catalogue six swept — which is the whole point of having swept it.
    func server(named name: String) -> MCPServerDefinition? {
        if let known = servers.first(where: { $0.id == name || $0.name == name }) { return known }
        return catalog.entries.first { $0.id == name || $0.name == name }?.definition
    }

    // MARK: What the agent is given

    /// Servers whose tools go to the agent through `six --mcp`. Empty by default, and deliberately:
    /// sharing a server means launching its process and putting somebody else's tools in front of
    /// the model, which is a decision, not a default.
    var sharedWithAgent: Set<String> {
        get { Set(settings?.mcpSharedServers ?? []) }
        set { settings?.mcpSharedServers = newValue.sorted() }
    }

    func isShared(_ definition: MCPServerDefinition) -> Bool { sharedWithAgent.contains(definition.id) }

    func setShared(_ definition: MCPServerDefinition, _ shared: Bool) {
        var current = sharedWithAgent
        if shared { current.insert(definition.id) } else { current.remove(definition.id) }
        sharedWithAgent = current
        if !shared, !sessions.contains(where: { $0.server.id == definition.id }) { disconnect(definition) }
        onSharedServersChanged?()
    }

    /// How long the whole of a shared server's answer to "what have you got" may take.
    ///
    /// Not `MCPClient`'s own two minutes. Those are for *calling* a tool, where somebody asked for
    /// work and is waiting on it; this is for reading a list of names, and the launch of an `npx`
    /// package with a cold cache is the slowest honest thing in it.
    private static let listingDeadline = Duration.seconds(15)

    /// Every shared server's model-visible tools, as MCP descriptors under six's own name.
    ///
    /// Asked all at once and each on a short clock. A server that will not start is skipped rather
    /// than failing the list — an agent asking six what it can do should get the browser's own tools
    /// even when somebody's npm package is broken — but skipping is not enough on its own: six's
    /// twenty-nine are collected before this is called and still leave only after it returns, so a
    /// server that accepts the connection and then says nothing would take the whole list with it,
    /// and the agent would find itself without a browser rather than without a server.
    func agentTools() async -> [ACPJSON] {
        // Independent `Task`s rather than a task group, the way `MCPCatalog.sweep` does it and for
        // the same measured reason. Each one is a client of its own, so nothing here is shared but
        // the order they are read back in.
        let running = servers.filter(isShared).map { definition in
            let client = client(for: definition)
            return Task { () -> (MCPServerDefinition, [MCPTool], String?) in
                do {
                    let tools = try await MCPApps.withDeadline(Self.listingDeadline) {
                        try await client.connect()
                        return try await client.listTools()
                    }
                    return (definition, tools, nil)
                } catch {
                    return (definition, [], error.localizedDescription)
                }
            }
        }
        var descriptors: [ACPJSON] = []
        for task in running {
            let (definition, tools, failure) = await task.value
            if let failure {
                lastError = "\(definition.name): \(failure)"
                continue
            }
            descriptors += tools.filter { $0.visibility.contains(.model) }
                .map { descriptor(for: $0, of: definition) }
        }
        return descriptors
    }

    /// One tool, as the agent will read it.
    private func descriptor(for tool: MCPTool, of definition: MCPServerDefinition) -> ACPJSON {
        var object: [String: ACPJSON] = [
            "name": .string(qualified(definition, tool)),
            "inputSchema": tool.inputSchema ?? ["type": "object", "properties": [:]],
        ]
        object["title"] = .string(tool.title ?? tool.name)
        // The agent is told which tools draw something, because that changes what it should say
        // afterwards: the window is the answer, and repeating it in prose is reading the screen
        // aloud.
        let note = tool.hasApp
            ? " Opens a window in the browser showing this result as an interface; describe it briefly rather than repeating its contents."
            : ""
        // The server's name is said in the description and not left to the prefix of the tool's
        // name. Somebody asking for "my cards in Kaiten" is naming the *server*, and the description
        // is what that gets matched against — while a server's own text has no reason to repeat its
        // own name, and usually does not. Without this the nearest match to the question is the
        // browser's own `open_url`, and the answer is the company's website instead of the window
        // its server would draw.
        let from = "From \(definition.name), a server this browser is connected to."
        var text = (tool.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Somebody else's sentence, which may or may not have been finished. six's own half follows
        // it either way, and "as a member Opens a window" is not a sentence.
        if let last = text.last, !".!?".contains(last) { text += "." }
        object["description"] = .string("\(from) \(text)\(note)")
        return .object(object)
    }

    /// Runs a tool the agent asked for by its qualified name. `nil` means the name is not six's to
    /// answer — the caller falls through to whatever else it knows.
    func callForAgent(_ name: String, arguments: ACPJSON) async -> ACPJSON? {
        guard let (definition, toolName) = split(name), isShared(definition) else { return nil }
        do {
            let client = client(for: definition)
            try await client.connect()
            _ = try await client.listTools()
            guard let tool = await client.tool(named: toolName), tool.visibility.contains(.model) else {
                return Self.result("\(definition.name) has no tool \(toolName).", isError: true)
            }
            // A tool with an interface behind it is answered twice: the window draws it, and the
            // agent is told in words that the window is there.
            if let uri = tool.uiResourceURI {
                let resource = try await uiResource(uri, from: definition, client: client)
                let session = makeSession(client: client, definition: definition, tool: tool,
                                          resource: resource, arguments: arguments)
                let result = await session.callTool()
                return Self.appResult(result, tool: tool)
            }
            return try await client.callTool(toolName, arguments: arguments)
        } catch {
            return Self.result(error.localizedDescription, isError: true)
        }
    }

    /// `<server>__<tool>`, with the server's own name first.
    func qualified(_ definition: MCPServerDefinition, _ tool: MCPTool) -> String {
        definition.id + Self.separator + tool.name
    }

    private func split(_ name: String) -> (MCPServerDefinition, String)? {
        // The server's id is matched first and the rest is the tool's name, so a tool whose own name
        // contains the separator still resolves.
        for definition in servers where name.hasPrefix(definition.id + Self.separator) {
            return (definition, String(name.dropFirst(definition.id.count + Self.separator.count)))
        }
        return nil
    }

    private static func result(_ text: String, isError: Bool = false) -> ACPJSON {
        var object: [String: ACPJSON] = ["content": [["type": "text", "text": .string(text)]]]
        if isError { object["isError"] = true }
        return .object(object)
    }

    /// What the agent reads when a window was opened: the server's own text, and a line saying where
    /// it went. A server that returned nothing at all still gets an answer worth reading.
    private static func appResult(_ result: ACPJSON?, tool: MCPTool) -> ACPJSON {
        let opened = "Opened \(tool.display) as a window in the browser."
        guard var object = result?.objectValue else { return Self.result(opened) }
        var content = object["content"]?.arrayValue ?? []
        content.append(["type": "text", "text": .string(opened)])
        object["content"] = .array(content)
        return .object(object)
    }

    /// The window closed. The session goes, and with it the server — unless another window is still
    /// drawing from it, or the agent has been given its tools.
    func forget(_ session: MCPAppSession) {
        sessions.removeAll { $0 === session }
        let definition = session.server
        guard !isShared(definition), !sessions.contains(where: { $0.server.id == definition.id }) else { return }
        disconnect(definition)
    }

    private func disconnect(_ definition: MCPServerDefinition) {
        clients[definition.id]?.closeDetached()
        clients[definition.id] = nil
        resources = resources.filter { !$0.key.hasPrefix(definition.id + "\u{1}") }
    }

    /// The app's document, read once per server and kept.
    private func uiResource(_ uri: String, from definition: MCPServerDefinition, client: MCPClient) async throws -> MCPUIResource {
        let key = definition.id + "\u{1}" + uri
        if let cached = resources[key] { return cached }
        let resource = try await client.readUIResource(uri)
        resources[key] = resource
        return resource
    }

    func client(for definition: MCPServerDefinition) -> MCPClient {
        if let client = clients[definition.id] { return client }
        let client = MCPClient(definition: definition, authorization: authorization)
        clients[definition.id] = client
        return client
    }

    /// Connects if need be, finds the tool, reads the interface behind it, and opens the window.
    ///
    /// The tool call is *not* awaited: the window loads and the app initializes while the call is in
    /// flight, and the result reaches the app as `ui/notifications/tool-result` whenever it lands.
    /// That is the order the spec's own lifecycle diagram draws.
    @discardableResult
    func open(_ definition: MCPServerDefinition, tool name: String? = nil,
              arguments: ACPJSON = [:], activate: Bool = true) async throws -> MCPAppSession {
        lastError = nil
        do {
            let client = client(for: definition)
            try await client.connect()
            let tools = try await client.listTools()
            let tool: MCPTool?
            if let name {
                tool = tools.first { $0.name == name }
            } else {
                tool = tools.first(where: \.hasApp)
            }
            guard let tool else { throw MCPClient.Failure.server("No tool \(name ?? "with an interface") on \(definition.name).") }
            guard let uri = tool.uiResourceURI else {
                throw MCPClient.Failure.server("\(tool.name) has no ui:// resource — it is a plain tool.")
            }
            let resource = try await uiResource(uri, from: definition, client: client)
            let session = makeSession(client: client, definition: definition, tool: tool,
                                      resource: resource, arguments: arguments, activate: activate)
            Task { await session.callTool() }
            return session
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Builds the session, gives it its window, and wires what it may ask six for.
    ///
    /// `replacing` is a window that is already in the strip — a restored one being run again — which
    /// keeps its place instead of a second one appearing beside it.
    private func makeSession(client: MCPClient, definition: MCPServerDefinition, tool: MCPTool,
                             resource: MCPUIResource, arguments: ACPJSON,
                             activate: Bool = true, replacing tabID: UUID? = nil) -> MCPAppSession {
        let session = MCPAppSession(client: client, server: definition, tool: tool,
                                    resource: resource, arguments: arguments)
        // `ui/message`: the app has something to say in the conversation, so it goes where the
        // person's own prompts go.
        #if os(macOS)
        session.onMessage = { [weak self] text in self?.agent?.send(text) }
        #endif
        session.onClose = { [weak self] session in self?.forget(session) }
        sessions.append(session)
        if let tabID {
            browser?.replaceWithApp(tabID, session: session)
        } else {
            browser?.newApp(session, activate: activate)
        }
        return session
    }

    // MARK: Windows that came back

    /// Which restored windows have been looked at, so a column scrolling past twice asks once.
    @ObservationIgnored private var examined: Set<UUID> = []
    /// Called when a restored app window first comes on screen.
    ///
    /// Asks the server one question — is this tool `readOnlyHint`? — and re-runs it only if the
    /// answer is yes. A tool call is much closer to a POST than to a GET: a browser re-fetches a
    /// page without asking and refuses to re-submit a form without asking, and this is the second
    /// kind. Everything else waits for the person to press the button.
    func examine(_ tab: BrowserTab, _ saved: AppWindowSnapshot) {
        guard examined.insert(tab.id).inserted else { return }
        Task { await rerun(saved, in: tab.id, onlyIfSafe: true) }
    }

    /// Runs a restored window's tool again and puts the app back in its column.
    func rerun(_ saved: AppWindowSnapshot, in tabID: UUID, onlyIfSafe: Bool = false) async {
        let definition = MCPServerDefinition(saved)
        do {
            let client = client(for: definition)
            try await client.connect()
            _ = try await client.listTools()
            guard let tool = await client.tool(named: saved.tool), let uri = tool.uiResourceURI else {
                lastError = "\(saved.serverName) no longer has \(saved.tool)."
                return
            }
            // Not read-only, and nobody pressed anything: the card stays and the question waits.
            if onlyIfSafe, !tool.isReadOnly { return }
            let resource = try await uiResource(uri, from: definition, client: client)
            let arguments = (try? JSONDecoder().decode(ACPJSON.self, from: Data(saved.toolArguments.utf8))) ?? [:]
            let session = makeSession(client: client, definition: definition, tool: tool,
                                      resource: resource, arguments: arguments, replacing: tabID)
            Task { await session.callTool() }
        } catch {
            lastError = "\(saved.serverName): \(error.localizedDescription)"
        }
    }

    #if os(macOS)
    /// `ui/update-model-context` from every running app, as the agent's next turn should see it.
    /// Read once per prompt: the spec says the last update before a user message is the one that
    /// counts, and an app that has said nothing new says nothing again.
    func pendingModelContext() -> [ACP.ContentBlock] {
        var blocks: [ACP.ContentBlock] = []
        for session in sessions {
            guard let context = session.takeModelContext() else { continue }
            let text = (context["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            let structured = context["structuredContent"].map(\.description) ?? ""
            let body = [text, structured].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            blocks.append(.text("From the \(session.title) window:\n\(body)"))
        }
        return blocks
    }
    #endif

    /// `SIX_MCP_APP_SELFTEST="basic-vanillajs"` — or `"map:show-map"` — opens one app on launch, the
    /// way `SIX_ACP_SELFTEST` sends one prompt: the whole path exercised without a click.
    func runSelfTestIfRequested() {
        guard let value = ProcessInfo.processInfo.environment["SIX_MCP_APP_SELFTEST"], !value.isEmpty else { return }
        // `http://host/mcp#tool` for a server that is not in the list yet, `<name>:<tool>` for one
        // that is. A URL has colons of its own, so it is recognised before the split.
        let definition: MCPServerDefinition
        let tool: String?
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            let halves = value.split(separator: "#", maxSplits: 1).map(String.init)
            guard let url = URL(string: halves[0]) else { return }
            definition = MCPServerDefinition(id: url.host() ?? "selftest", url: url)
            tool = halves.count > 1 ? halves[1] : nil
        } else {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            definition = server(named: parts[0]) ?? .example(parts[0])
            tool = parts.count > 1 ? parts[1] : nil
        }
        Task {
            do {
                _ = try await open(definition, tool: tool)
            } catch {
                FileHandle.standardError.write(Data("[six] mcp app selftest: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}

extension MCPServerDefinition {
    /// The server a restored window remembers. Lives here rather than beside the type: `MCPAppTypes`
    /// is the wire format and knows nothing about what six writes to disk.
    init(_ saved: AppWindowSnapshot) {
        self.init(id: saved.serverID, name: saved.serverName, command: saved.command,
                  arguments: saved.commandArguments)
        url = saved.url
    }
}
