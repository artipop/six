import SwiftUI
import AppKit
import WebKit

/// Inspector panel for talking to an ACP agent (Claude Code, Codex) about the current project.
struct AgentPanel: View {
    @Environment(AgentSessionStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Environment(MCPHost.self) private var mcp
    @State private var input = ""
    @State private var attachPage = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let prompt = store.permissionPrompt {
                Divider()
                PermissionView(prompt: prompt)
            }
            Divider()
            composer
        }
        .frame(minWidth: 320)
    }

    private var header: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Agent", selection: $store.agent) {
                    ForEach(ACPAgentDefinition.builtIn) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                Spacer()
                stateBadge
            }
            // The agent works in the profile's own folder; that stays out of the way unless the user picked another.
            HStack(spacing: 6) {
                Image(systemName: "folder")
                if browser.selectedProfile.hasCustomWorkingDirectory {
                    Text(store.workingDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                    Button { browser.setWorkingDirectory(nil, for: browser.selectedProfileID) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to the profile's own folder")
                } else {
                    Text("\(browser.selectedProfile.name) folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(store.workingDirectory.path(percentEncoded: false))
                }
                Spacer()
                Button("Choose…") { chooseDirectory() }
                    .controlSize(.small)
            }
            ToolchainStatusView(agent: store.agent)
            Label("Browser tools via MCP: \(mcp.server.toolNames.joined(separator: ", "))", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help("The agent's session gets `six --mcp` as an MCP server. \(mcp.status)")
            if store.agent.id == ACPAgentDefinition.claudeCode.id {
                TextField("Model override (ANTHROPIC_MODEL, optional)", text: $store.modelOverride)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            if let modes = store.modes, !modes.availableModes.isEmpty {
                Picker("Mode", selection: Binding(get: { modes.currentModeId }, set: { store.setMode($0) })) {
                    ForEach(modes.availableModes) { Text($0.name).tag($0.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch store.state {
        case .idle: Text("Idle").foregroundStyle(.secondary).font(.caption)
        case .starting: ProgressView().controlSize(.small)
        case .ready: Label("Ready", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
        case .prompting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Button("Stop") { store.cancel() }.controlSize(.small)
            }
        case .failed:
            Button { Task { await store.connect() } } label: { Label("Retry", systemImage: "exclamationmark.triangle") }
                .controlSize(.small)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if case .failed(let message) = store.state {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(store.transcript) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: store.transcript.count) { _, _ in
                if let last = store.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            TextField("Message \(store.agent.name)…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit(send)
            HStack {
                Toggle("Attach page", isOn: $attachPage).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || store.state == .prompting)
            }
        }
        .padding(10)
    }

    private func send() {
        var context: [ACP.ContentBlock] = []
        if attachPage, let tab = browser.selectedTab, let url = tab.page.url {
            context.append(.resourceLink(uri: url.absoluteString, name: tab.title, mimeType: "text/html", title: tab.title))
        }
        store.send(input, context: context)
        input = ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = store.workingDirectory
        if panel.runModal() == .OK, let url = panel.url { browser.setWorkingDirectory(url, for: browser.selectedProfileID) }
    }
}

/// Shows whether the ACP adapter and its CLI are installed; offers to install the adapter with npm.
private struct ToolchainStatusView: View {
    let agent: ACPAgentDefinition
    @Environment(AgentSessionStore.self) private var store
    @State private var showLog = false

    private var toolchain: AgentToolchain { store.toolchain }
    private var report: AgentToolchain.Report { toolchain.report(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch report.adapter {
                case .unknown, .checking:
                    ProgressView().controlSize(.mini)
                    Text("Checking \(agent.binaryName)…")
                case .installed(let path):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(agent.binaryName).help(path)
                case .installable:
                    Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                    Text("\(agent.binaryName) not installed (runs via npx)")
                    Spacer()
                    if report.isInstalling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Install") { Task { await toolchain.install(agent) } }
                    }
                case .nodeMissing:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("Node.js / npm not found")
                    Spacer()
                    Link("Install Node.js", destination: AgentToolchain.nodeInstallURL)
                }
                if report.adapter != .checking {
                    Button { Task { await toolchain.refresh(agent) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Re-check")
                }
            }
            HStack(spacing: 6) {
                if report.underlyingCLIPath != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(agent.underlyingCLI) CLI")
                } else if report.adapter != .unknown, report.adapter != .checking {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(agent.underlyingCLI) CLI not found. \(agent.loginHint)")
                }
            }
            if !report.installLog.isEmpty {
                DisclosureGroup("Install log", isExpanded: $showLog) {
                    ScrollView {
                        Text(report.installLog).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .task(id: agent.id) {
            if report.adapter == .unknown { await toolchain.refresh(agent) }
        }
    }
}

private struct TranscriptRow: View {
    let item: AgentTranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .padding(8)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent(let text):
            Text(LocalizedStringKey(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .thought(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).italic().lineLimit(6)
        case .status(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .plan(let entries):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Label(entry.content, systemImage: entry.status == .completed ? "checkmark.circle.fill" : entry.status == .inProgress ? "circle.dotted" : "circle")
                        .font(.caption)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        case .toolCall(let call):
            ToolCallRow(call: call)
        }
    }
}

private struct ToolCallRow: View {
    let call: ACP.ToolCall
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((call.content ?? []).enumerated()), id: \.offset) { _, content in
                    switch content {
                    case .content(let block):
                        Text(block.plainText ?? "").font(.caption.monospaced()).textSelection(.enabled)
                    case .diff(let path, _, let newText):
                        Text(path).font(.caption.bold())
                        Text(newText).font(.caption.monospaced()).lineLimit(20).textSelection(.enabled)
                    case .terminal(let id):
                        Text("terminal \(id)").font(.caption)
                    }
                }
                if let input = call.rawInput, call.content?.isEmpty ?? true {
                    Text(input.description).font(.caption.monospaced()).lineLimit(10).textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(call.title ?? call.toolCallId).lineLimit(1)
                Spacer()
                if call.status == .inProgress || call.status == .pending { ProgressView().controlSize(.mini) }
            }
            .font(.callout)
        }
    }

    private var symbol: String {
        switch call.kind {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "brain"
        case .fetch: "globe"
        default: "wrench"
        }
    }

    private var color: Color {
        switch call.status {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }
}

struct PermissionView: View {
    let prompt: AgentPermissionPrompt
    @Environment(AgentSessionStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permission requested", systemImage: "hand.raised.fill").font(.headline)
            Text(prompt.request.toolCall.title ?? prompt.request.toolCall.toolCallId)
                .font(.callout)
            if let input = prompt.request.toolCall.rawInput {
                Text(input.description).font(.caption.monospaced()).lineLimit(6).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(prompt.request.options) { option in
                    Button(option.name) { store.resolvePermission(.selected(optionId: option.optionId)) }
                        .tint(option.kind == .allowOnce || option.kind == .allowAlways ? .green : .red)
                }
                Spacer()
                Button("Cancel") { store.resolvePermission(.cancelled) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.1))
    }
}

extension FocusedValues {
    @Entry var toggleAgentPanel: FocusAddressBarAction?
}
