import SwiftUI

/// MCP connections, embedded in Assistant settings on macOS.
/// The saved servers stay on this page; registry search and the app catalogue open in a separate sheet.
struct MCPAppsView: View {
    @Environment(MCPAppStore.self) private var apps
    @State private var isAdding = false
    /// The server whose OAuth client is being filled in. A separate sheet from `isAdding` only in
    /// what it starts from: the same form, opened on something that already exists.
    @State private var editing: MCPServerDefinition?
    @State private var query = ""
    @State private var results: [MCPRegistry.Entry] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var discovering = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button("Add Server…") { isAdding = true }
                        Button("Browse MCP Catalog…") { discovering = true }
                    }
                    Text("Connect tools and apps by command or URL. Turn on Agent Access for the servers your agents should use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if apps.customServers.isEmpty {
                        Label("No Connected Servers", systemImage: "server.rack")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                    ForEach(apps.customServers) { server in
                        MCPServerRow(server: server) { editing = server }
                    }
                } header: {
                    // "Agent Access" names the column of switches, once. On the row it was the same
                    // three words down every server, which is a heading pretending to be a label.
                    HStack {
                        Text("Connected Servers")
                        Spacer()
                        if !apps.customServers.isEmpty { Text("Agent Access") }
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .background(.background)
        .sheet(isPresented: $isAdding) { MCPAddServerSheet() }
        .sheet(item: $editing) { MCPAddServerSheet(editing: $0) }
        .sheet(isPresented: $discovering) { discovery }
    }

    private var discovery: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MCP Catalog").font(.headline)
                Spacer()
                Button("Done") { discovering = false }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            searchField
            Divider()
            discoveryList
            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 400, idealHeight: 600)
        .task(id: query) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the MCP registry", text: $query)
                .textFieldStyle(.plain)
            if isSearching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var discoveryList: some View {
        List {
            if !query.isEmpty {
                Section("Registry Results") {
                    if let searchError {
                        Text(searchError).font(.caption).foregroundStyle(.secondary)
                    } else if results.isEmpty, !isSearching {
                        Text("Nothing in the registry matches.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(results) { entry in
                        MCPFoundRow(entry: entry)
                    }
                }
            }
            if !catalogue.isEmpty {
                Section {
                    ForEach(catalogue) { entry in
                        MCPCatalogRow(entry: entry)
                    }
                } header: {
                    HStack {
                        Text("Apps")
                        Spacer()
                        Text(swept).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = apps.authorization.lastError ?? apps.lastError {
            Text(error).font(.caption).foregroundStyle(.red).padding(10)
        } else {
        }
    }

    /// Searches, then goes and asks the results whether they have anything to draw.
    ///
    /// Only the remote ones, and only the first few: a remote server costs two HTTP requests, while
    /// a package costs a download and a process, and nobody typing in a search field agreed to that.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1 else {
            results = []
            searchError = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await MCPRegistry.search(text)
            guard !Task.isCancelled else { return }
            results = found
            searchError = nil
            await probe(found.filter(\.isRemote).prefix(8))
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = error.localizedDescription
        }
    }

    private func probe(_ entries: some Collection<MCPRegistry.Entry>) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for entry in entries {
                guard let definition = entry.definition() else { continue }
                if running >= 4 {
                    await group.next()
                    running -= 1
                }
                group.addTask { @MainActor in await apps.probe(definition) }
                running += 1
            }
        }
    }

    /// The catalogue, narrowed by whatever is in the search field.
    private var catalogue: [MCPCatalog.Entry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return apps.catalog.entries }
        return apps.catalog.entries.filter {
            $0.name.lowercased().contains(text) || $0.description.lowercased().contains(text)
                || $0.namespace.lowercased().contains(text)
        }
    }

    /// Where the list came from and when. Both, because an entry is a fact about a server on a
    /// day, and the day on its own does not say who was asked.
    private var swept: String {
        guard apps.catalog.generated > .distantPast else { return "" }
        let day = apps.catalog.generated.formatted(date: .abbreviated, time: .omitted)
        guard let host = URL(string: apps.catalog.source)?.host() else {
            return String(localized: "checked \(day)")
        }
        return String(localized: "\(host), checked \(day)")
    }

}

/// One server from six's own catalogue: already known to draw something.
private struct MCPCatalogRow: View {
    @Environment(MCPAppStore.self) private var apps
    let entry: MCPCatalog.Entry

    var body: some View {
        HStack(spacing: 10) {
            // A window either way, with the mark of a process on the ones that are one: adding a
            // remote server is remembering an address, and adding a local one is agreeing to launch
            // something. The row should not make those look like the same button.
            Image(systemName: entry.isRemote ? "macwindow" : "terminal")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).lineLimit(1)
                    Text("\(entry.apps) of \(entry.tools)")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                if !entry.description.isEmpty {
                    Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(entry.appTools.joined(separator: ", ")).lineLimit(1)
                    // Only for an entry that did not come from the sweep the section header names.
                    // Saying "registry" on all three hundred rows would be noise; saying nothing on
                    // the one that somebody added by hand would be a list nobody can audit.
                    if let source = entry.source {
                        Text(source).foregroundStyle(.tint)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if isAdded {
                Button("Open") { Task { try? await apps.open(entry.definition) } }
                    .controlSize(.small)
            } else {
                Button("Add") { apps.add(entry.definition) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private var isAdded: Bool {
        apps.customServers.contains { $0.location == entry.definition.location }
    }
}

/// A result from the registry, with whatever probing it turned up.
private struct MCPFoundRow: View {
    @Environment(MCPAppStore.self) private var apps
    let entry: MCPRegistry.Entry
    /// A package whose publisher declared a variable with no value — an API key, nearly always.
    /// Added as it is, it would start and fail on the first call, so the form opens on it first.
    @State private var needsEnvironment: MCPServerDefinition?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isRemote ? "network" : "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.display).lineLimit(1)
                    MCPProbeBadge(probe: entry.definition().flatMap { apps.probeResult(for: $0) })
                }
                Text(entry.description.isEmpty ? entry.name : entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(entry.namespace).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if isAdded {
                Text("Added").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    guard let definition = entry.definition() else { return }
                    if definition.missingEnvironment.isEmpty { apps.add(definition) } else { needsEnvironment = definition }
                }
                .controlSize(.small)
                .disabled(entry.definition() == nil)
            }
        }
        .padding(.vertical, 3)
        .task { await probeIfCheap() }
        .sheet(item: $needsEnvironment) { MCPAddServerSheet(editing: $0, isNew: true) }
    }

    private var isAdded: Bool {
        guard let definition = entry.definition() else { return false }
        return apps.customServers.contains { $0.location == definition.location }
    }

    /// A package is not probed on sight: launching somebody's npm package is not something a search
    /// result gets to do on its own. The row asks once it is on screen only when it is a URL.
    private func probeIfCheap() async {
        guard entry.isRemote, let definition = entry.definition(), apps.probeResult(for: definition) == nil else { return }
        await apps.probe(definition)
    }
}

/// What connecting to a server found, said in as few words as a row has room for.
private struct MCPProbeBadge: View {
    let probe: MCPAppStore.Probe?

    var body: some View {
        switch probe {
        case .probing:
            ProgressView().controlSize(.mini)
        case .answered(let tools, let apps) where apps > 0:
            Label("\(apps) of \(tools) have an interface", systemImage: "macwindow")
                .font(.caption2)
                .foregroundStyle(.tint)
                .labelStyle(.titleAndIcon)
        case .answered(let tools, _):
            Text("\(tools) tools, no interface").font(.caption2).foregroundStyle(.secondary)
        case .needsSignIn:
            Label("sign-in required", systemImage: "lock").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Label("did not answer", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

private struct MCPServerRow: View {
    @Environment(MCPAppStore.self) private var apps
    let server: MCPServerDefinition
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.isRemote ? "network" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.body.weight(.medium))
                Text(server.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(server.location)
                if !server.missingEnvironment.isEmpty {
                    Label("Not set: \(server.missingEnvironment.joined(separator: ", "))", systemImage: "key")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                MCPProbeBadge(probe: apps.probeResult(for: server))
            }
            Spacer(minLength: 12)
            Toggle("Agent Access", isOn: Binding(
                get: { apps.isShared(server) },
                set: { apps.setShared(server, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Give this server's tools to the agent")
            Menu {
                Button("Edit…", action: edit)
                Button("Check Connection") { Task { await apps.probe(server, force: true, authorize: true) } }
                    .disabled(apps.probeResult(for: server) == .probing)
                if apps.probeResult(for: server)?.appCount != 0 {
                    Button("Open App") { Task { try? await apps.open(server) } }
                }
                if server.isRemote {
                    Divider()
                    if isSignedIn {
                        Button("Sign Out") { apps.authorization.signOut(server) }
                    } else {
                        Button("Sign In…") { Task { _ = await apps.authorization.authorize(server, challenge: nil) } }
                    }
                }
                Divider()
                Button("Remove", role: .destructive) { apps.remove(server) }
            } label: {
                Label("Server Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Server Actions")
        }
        .padding(.vertical, 8)
        .task(id: server) { await probeIfCheap() }
    }

    private var isSignedIn: Bool { apps.authorization.signedIn.contains(server.id) }

    /// Two HTTP requests for a remote server, and nothing at all for a local one — launching a
    /// process to fill in a row is not what opening a panel asked for.
    private func probeIfCheap() async {
        guard server.isRemote, !isSignedIn, apps.probeResult(for: server) == nil else { return }
        await apps.probe(server)
    }
}

/// Adding one by hand, or filling in what a server needs later: a name, and either a command line
/// or a URL. Nothing else is required, because nothing else is: a server is a process or an address.
///
/// The OAuth section is the exception, and it is empty for almost everyone. six registers itself
/// with a server that lets it (RFC 7591); a provider whose clients are created in a console —
/// Google's Workspace servers — hands out none, and then the id, the secret and the scopes have to
/// be typed in. The redirect URI shown there is what gets pasted back into that console.
private struct MCPAddServerSheet: View {
    @Environment(MCPAppStore.self) private var apps
    @Environment(\.dismiss) private var dismiss
    /// The server being changed, or nil when this is a new one.
    var editing: MCPServerDefinition?
    /// `editing` is a registry entry being added, not something already saved.
    var isNew = false

    @State private var name = ""
    @State private var isRemote = false
    @State private var commandLine = ""
    @State private var variables: [Variable] = []
    @State private var address = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var scopes = ""
    @State private var issuer = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil || isNew ? "Add a Server" : "Edit a Server").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("weather"))
                Picker("Kind", selection: $isRemote) {
                    Text("Command").tag(false)
                    Text("URL").tag(true)
                }
                .pickerStyle(.segmented)
                if isRemote {
                    TextField("Address", text: $address, prompt: Text("https://example.com/mcp"))
                    TextField("Token", text: $token, prompt: Text("optional — sent as a bearer token"))
                    oauthSection
                } else {
                    TextField("Command", text: $commandLine,
                              prompt: Text("npx -y @modelcontextprotocol/server-map --stdio"))
                }
                if !isRemote { environmentSection }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil || isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
        }
        .padding(16)
        .frame(width: (Platform.screenSize.width * 0.28).rounded())
        .task { load() }
    }

    /// A row per variable, the value exactly as typed — nothing is quoted or escaped, because nothing
    /// goes through a shell. A `NAME=value` line pasted into a name field is split into rows, so a
    /// README's line or a whole `.env` file still pastes in one go.
    private var environmentSection: some View {
        Section("Environment") {
            ForEach($variables) { $variable in
                HStack(spacing: 8) {
                    TextField("Name", text: $variable.name, prompt: Text(verbatim: "API_TOKEN"))
                        .onChange(of: variable.name) { _, name in expand(variable.id, name) }
                    TextField("Value", text: $variable.value, prompt: Text("Value"))
                    Button {
                        variables.removeAll { $0.id == variable.id }
                    } label: {
                        Label("Remove", systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
                .labelsHidden()
                .font(.body.monospaced())
            }
            Button("Add Variable") { variables.append(Variable()) }
        }
    }

    private struct Variable: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    private func expand(_ id: UUID, _ name: String) {
        guard name.contains("="), let index = variables.firstIndex(where: { $0.id == id }) else { return }
        let pasted = Self.pairs(in: name).map { Variable(name: $0.name, value: $0.value) }
        guard !pasted.isEmpty else { return }
        variables.replaceSubrange(index...index, with: pasted)
    }

    /// Shown collapsed: a server that registers its own clients — nearly all of them — needs
    /// nothing here, and an empty form open by default reads as four more things to fill in.
    private var oauthSection: some View {
        DisclosureGroup("OAuth client") {
            TextField("Client ID", text: $clientID, prompt: Text("only for a server that issues none"))
            SecureField("Client secret", text: $clientSecret, prompt: Text("kept in the Keychain"))
            TextField("Scopes", text: $scopes, prompt: Text("space-separated, when the server names none"))
            TextField("Issuer", text: $issuer, prompt: Text("https://accounts.google.com"))
            LabeledContent("Redirect URI") {
                HStack(spacing: 6) {
                    Text(redirectURI)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Copy") { Platform.copy(redirectURI) }
                        .controlSize(.small)
                }
            }
            .help("Register this address with the provider")
        }
    }

    /// The loopback address this server's sign-in will come back to. It follows the identifier, so
    /// it is settled before anything is saved and can be registered with the provider first.
    private var redirectURI: String {
        MCPOAuthClient(clientID: "", redirectPort: MCPOAuthClient.port(for: identifier)).redirectURI
    }

    private var isComplete: Bool {
        guard !identifier.isEmpty else { return false }
        return isRemote ? URL(string: address)?.scheme?.hasPrefix("http") == true
                        : !commandLine.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The name on the wire: what prefixes this server's tools, so no spaces and nothing exotic.
    /// A server being edited keeps the one it already has — it is what its tools, its token and its
    /// registered redirect URI are all named after.
    private var identifier: String {
        if let editing { return editing.id }
        return String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
    }

    private func load() {
        guard let editing, !loaded else { return }
        loaded = true
        name = editing.name
        isRemote = editing.isRemote
        address = editing.url?.absoluteString ?? ""
        token = editing.headers["Authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") } ?? ""
        commandLine = editing.shellCommandLine
        variables = editing.environment.sorted { $0.key < $1.key }
            .map { Variable(name: $0.key, value: $0.value) }
        clientID = editing.oauth?.clientID ?? ""
        scopes = editing.oauth?.scopes.joined(separator: " ") ?? ""
        issuer = editing.oauth?.issuer?.absoluteString ?? ""
        clientSecret = MCPTokenStore.clientSecret(editing.id) ?? ""
    }

    private func save() {
        var definition: MCPServerDefinition
        if isRemote, let url = URL(string: address) {
            var headers: [String: String] = [:]
            let token = token.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
            definition = MCPServerDefinition(id: identifier, name: name, url: url, headers: headers)
            definition.oauth = oauthClient
        } else {
            // A command line is split the way a shell would split it, minus the quoting: the first
            // word is the program, the rest are its arguments. Nothing runs through a shell — see
            // `MCPServerProcess` — so a word with a semicolon in it is an argument, not a command.
            var words = commandLine.split(separator: " ").map(String.init)
            let command = words.isEmpty ? "" : words.removeFirst()
            definition = MCPServerDefinition(id: identifier, name: name, command: command, arguments: words,
                                             environment: environment)
        }
        // The secret follows the id, not the definition: an emptied field deletes it.
        MCPTokenStore.setClientSecret(definition.oauth == nil ? "" : clientSecret.trimmingCharacters(in: .whitespaces),
                                      for: identifier)
        apps.add(definition)
        dismiss()
    }

    /// The rows as the definition keeps them. A row with a name and no value stays: it is a
    /// variable still to be filled in, and `MCPServerProcess` does not pass it.
    private var environment: [String: String] {
        Dictionary(variables.compactMap { variable in
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, variable.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }, uniquingKeysWith: { $1 })
    }

    /// What a pasted `NAME=value` line holds, split the way a shell splits it: by whitespace or new lines, with
    /// quotes keeping a value's spaces — so `A=1 B="two words"` on one line, a `.env` file and a
    /// README's `export A=1` all paste as they are. A word with no `=` (`export` among them) is
    /// skipped, and a `#` starting a word comments out the rest of its line.
    private static func pairs(in text: String) -> [(name: String, value: String)] {
        var words: [String] = []
        var word = "", quote: Character?, inWord = false, inComment = false
        for character in text {
            if inComment {
                if character.isNewline { inComment = false }
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else if character == "#", !inWord {
                inComment = true
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }

        return words.compactMap { word in
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return nil }
            return (String(word[..<equals]), String(word[word.index(after: equals)...]))
        }
    }

    private var oauthClient: MCPOAuthClient? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        return MCPOAuthClient(
            clientID: id,
            redirectPort: MCPOAuthClient.port(for: identifier),
            issuer: URL(string: issuer.trimmingCharacters(in: .whitespaces)),
            scopes: scopes.split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }
}


/// Whichever of six's own pages a column is showing.
///
/// One switch, so a second built-in page is a case here and a case in `BuiltInPage`, and nothing in
/// the layout has to learn about it.
struct BuiltInPageView: View {
    let page: BuiltInPage
    let tab: BrowserTab

    var body: some View {
        switch page {
        #if os(iOS)
        case .apps: MCPAppsView()
        #endif
        #if os(macOS)
        case .configuration: ConfigurationPageView(tab: tab)
        case .welcome: WelcomePage(tab: tab)
        case .chats: AgentChatsPage(tab: tab)
        case .chat: AgentChatPage(tab: tab)
        #endif
        }
    }
}
