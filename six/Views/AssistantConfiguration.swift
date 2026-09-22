#if os(macOS)
import SwiftUI

struct AssistantPane: View {
    /// This pane's half of the address, from `ConfigurationPageView`: `agents` of
    /// `configuration/assistant#agents`. Held there because the address belongs to the window and outlives this
    /// view, which is rebuilt every time the sidebar leaves the pane and comes back.
    @Binding var part: String?

    @Environment(ConfigurationStore.self) private var store
    @State private var page = Page.line

    private enum Page: String, CaseIterable, Identifiable {
        /// Named for the surface it configures rather than for what comes back from it: "Responses"
        /// said what the answers are, not where they appear, and the ⌘E line is the where.
        case line
        case agents
        /// `mcp` on the wire, because that is what the tab is called; `servers` is what it holds.
        case servers = "mcp"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .line: String(localized: "⌘E Line")
            case .agents: String(localized: "Agents")
            case .servers: "MCP"
            }
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Picker("Assistant Settings", selection: $page) {
                    ForEach(Page.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                // Over all three tabs, because it reaches all three. An MCP server is here to hand
                // its tools to an agent; with no agent running there is nothing for it to hand them
                // to, so switching the models off switches it off too and the switch means what it
                // says — everything, not most of it.
                Toggle("Use Language Models and Agents", isOn: $store.isAIEnabled)
                    .toggleStyle(.switch)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: ConfigurationPageView.tabBarHeight)
            Divider()
            Group {
                switch page {
                case .line: AssistantResponsesConfiguration()
                case .agents: AgentConfiguration()
                case .servers: MCPAppsView()
                }
            }
            .disabled(!store.isAIEnabled)
            .padding(.top, ConfigurationPageView.contentInset)
        }
        .onAppear { if let named = part.flatMap(Page.init(rawValue:)) { page = named } }
        .onChange(of: part) { if let named = part.flatMap(Page.init(rawValue:)), named != page { page = named } }
        // The tab that opens by default has no anchor: `…/assistant` already means this one, and an
        // address that names it would be a second spelling of the same place.
        .onChange(of: page) {
            let named = page == Page.allCases[0] ? nil : page.rawValue
            if part != named { part = named }
        }
    }
}

private struct AssistantResponsesConfiguration: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(ConfigurationStore.self) private var store
    @Environment(DevToolsStore.self) private var devTools

    var body: some View {
        @Bindable var devTools = devTools
        Form {
            // No header: the tab above is called ⌘E Line and this is what it holds.
            Section {
                Picker("Assistant", selection: provider) {
                    ForEach(ModelChoice.languageModels) { choice in
                        Text(choice.title).tag(choice.rawValue)
                            .disabled(choice.isThirdParty && !FoundationModelsCompatibility.supportsThirdPartyModels)
                    }
                    Text("Claude Code").tag(ModelChoice.claudeCodeAgent.rawValue)
                    Text("Codex").tag(ModelChoice.codexAgent.rawValue)
                    ForEach(store.customAgents) { agent in
                        Text(agent.name).tag("custom:" + agent.id)
                    }
                }
                .pickerStyle(.menu)
                Text("Answers questions and works with selected text on the page (⌘E).")
                    .font(.caption).foregroundStyle(.secondary)
                if let agent = assistant.settings.model.agentDefinition {
                    AgentModelPicker(agent: agent)
                }
                if !FoundationModelsCompatibility.supportsThirdPartyModels {
                    Text("Remote models unavailable: SDK/OS Foundation Models mismatch")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            AssistantProviderConfiguration()
            Section("Access") {
                Toggle("Access to Page Console and Network", isOn: $devTools.isCapturing)
                    .toggleStyle(.switch)
                Text("Agents can read console messages and network requests. Changing this setting reloads open pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var provider: Binding<String> {
        Binding(get: {
            if assistant.settings.model == .customAgent, let selected = store.selectedCustomAgent {
                return "custom:" + selected.id
            }
            return assistant.settings.model.rawValue
        }, set: { value in
            if value.hasPrefix("custom:") {
                store[.selectedCustomAgent] = String(value.dropFirst("custom:".count))
                assistant.settings.model = .customAgent
            } else if let choice = ModelChoice(rawValue: value) {
                assistant.settings.model = choice
            }
        })
    }
}

struct AgentModelPicker: View {
    let agent: ACPAgentDefinition
    @Environment(AgentSessionStore.self) private var session

    private var discovery: AgentModelDiscovery { session.modelDiscovery }
    private var choices: [AgentModels.Model] { discovery.catalogs[agent.id]?.choices ?? [] }
    private var selected: String {
        let saved = session.selectedModel(for: agent)
        return saved.isEmpty ? (discovery.catalogs[agent.id]?.current ?? "") : saved
    }
    private var busy: Bool { session.state == .prompting || session.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if choices.isEmpty {
                    LabeledContent("Model") {
                        Text(discovery.loading.contains(agent.id)
                             ? LocalizedStringKey("Loading Models…") : LocalizedStringKey("Model List Unavailable"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Model", selection: Binding(get: { selected }, set: { session.selectModel($0, for: agent) })) {
                        ForEach(choices) { Text($0.name).tag($0.id) }
                        if selected.isEmpty {
                            Text("Select Model").tag("").disabled(true)
                        } else if !choices.contains(where: { $0.id == selected }) {
                            Text(selected).tag(selected).disabled(true)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(busy)
                }
                if discovery.loading.contains(agent.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh Models")
                }
            }
            if let error = discovery.errors[agent.id] {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: agent) {
            if discovery.catalogs[agent.id] == nil { await refresh() }
        }
    }

    private func refresh() async {
        await discovery.refresh(agent, toolchain: session.toolchain, directory: session.workingDirectory)
    }
}

private struct AgentConfiguration: View {
    @Environment(ConfigurationStore.self) private var store
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var session
    @State private var adding = false
    @State private var editing: ACPAgentDefinition?

    var body: some View {
        Form {
            Section {
                Text("Set up Claude Code or Codex, or connect another agent that supports ACP. Which one answers is chosen in ⌘E Line.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Add Agent…") { adding = true }
            }
            ForEach(ACPAgentDefinition.builtIn) { agent in
                Section(agent.name) {
                    AgentToolchainRow(agent: agent)
                    AgentLoginInstructions(agent: agent)
                }
            }
            ForEach(store.customAgents) { agent in
                Section(agent.name) {
                    Text(agent.shellCommandLine).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Edit…") { editing = agent }
                        Spacer()
                        Button("Remove", role: .destructive) { remove(agent) }
                    }
                    .disabled(session.state == .prompting || session.state == .starting)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AgentEditorSheet() }
        .sheet(item: $editing) { AgentEditorSheet(editing: $0) }
    }

    private func remove(_ agent: ACPAgentDefinition) {
        if assistant.settings.model.agentDefinition?.id == agent.id { assistant.settings.model = .claudeCodeAgent }
        if session.agent.id == agent.id { session.agent = .claudeCode }
        store.customAgents.removeAll { $0.id == agent.id }
        session.modelDiscovery.forget(agent)
    }
}

private struct AgentLoginInstructions: View {
    let agent: ACPAgentDefinition
    @State private var terminalError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(agent.loginHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let command = agent.loginCommand {
                HStack {
                    Text(verbatim: command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button {
                        Platform.copy(command)
                    } label: {
                        Label("Copy Command", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button("Open Terminal") {
                        Task { await openTerminal() }
                    }
                }
            }
            if let terminalError {
                Text(terminalError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func openTerminal() async {
        terminalError = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            terminalError = String(localized: "Terminal could not be found.")
            return
        }
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            terminalError = error.localizedDescription
        }
    }
}

private struct AgentEditorSheet: View {
    var editing: ACPAgentDefinition?
    @Environment(ConfigurationStore.self) private var store
    @Environment(AgentSessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var arguments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? LocalizedStringKey("Add Agent") : LocalizedStringKey("Edit Agent")).font(.headline)
            Text("Connect an ACP agent using its executable and launch arguments. It uses your shell environment and existing sign-in.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Executable", text: $command, prompt: Text("/path/to/agent or npx"))
                TextField("Arguments", text: $arguments, axis: .vertical)
                    .lineLimit(3...6)
                Text("One argument per line; no shell quotes needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            guard let editing else { return }
            name = editing.name
            command = editing.command
            arguments = editing.arguments.joined(separator: "\n")
        }
    }

    private func save() {
        let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var agent = editing ?? ACPAgentDefinition(id: UUID().uuidString, name: "", command: "", arguments: [],
            npmPackage: "", binaryName: "", underlyingCLI: "", loginHint: AttributedString(""))
        agent.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.command = executable
        agent.arguments = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var agents = store.customAgents
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent }
        else { agents.append(agent) }
        store.customAgents = agents
        session.modelDiscovery.forget(agent)
        if session.agent.id == agent.id { session.agent = agent }
        dismiss()
    }
}
#endif
