#if os(macOS)
import SwiftUI

/// The adapters behind the agent panel: which one is installed, how old it is, and the buttons that
/// put that right. They live on `six://configuration` ▸ Assistant and not in the panel, because
/// installing an adapter is a setting and not a thing you do while working — the panel says *that*
/// something is wrong and shows the way here, which is the rule the deleted menus left behind
/// (`MacCommands`: a menu item is a verb, everything else is a setting).
struct AgentToolchainSection: View {
    @Environment(AgentSessionStore.self) private var store

    var body: some View {
        Section("Agents") {
            ForEach(ACPAgentDefinition.builtIn) { agent in
                AgentToolchainRow(agent: agent)
            }
        }
    }
}

/// One adapter, with everything about it said in the order it matters: what six will run, how old it
/// is, and whether the CLI it drives is there at all.
struct AgentToolchainRow: View {
    let agent: ACPAgentDefinition

    @Environment(AgentSessionStore.self) private var store
    @State private var showLog = false

    private var toolchain: AgentToolchain { store.toolchain }
    private var report: AgentToolchain.Report { toolchain.report(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(agent.name).font(.body)
                Spacer()
                status
            }
            // The two versions are not one version, and reading the adapter's as the CLI's cost a
            // session: Codex updated to 0.154 on the machine while the adapter beside it carried
            // 0.147 of its own and refused today's model. Both numbers, both named.
            if let version = report.underlyingCLIVersion {
                Text(verbatim: "\(agent.underlyingCLI) \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if report.underlyingCLIPath == nil, report.adapter != .unknown, report.adapter != .checking {
                Label {
                    Text("\(agent.underlyingCLI) CLI not found. \(agent.loginHint)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            if !report.installLog.isEmpty {
                DisclosureGroup("Install log", isExpanded: $showLog) {
                    ScrollView {
                        Text(report.installLog).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
            }
        }
        .task(id: agent.id) {
            if report.adapter == .unknown { await toolchain.refresh(agent) }
        }
    }

    @ViewBuilder private var status: some View {
        switch report.adapter {
        case .unknown, .checking:
            ProgressView().controlSize(.mini)
        case .installed(let path):
            if let update = report.update {
                Text("Adapter \(update.from) — \(update.to) is out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(path)
                button("Update")
            } else {
                Text("Adapter \(report.installedVersion ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(path)
                recheck
            }
        case .installable:
            Text("runs through npx")
                .font(.caption)
                .foregroundStyle(.secondary)
            button("Install")
        case .nodeMissing:
            Link("Install Node.js", destination: AgentToolchain.nodeInstallURL)
                .font(.caption)
        }
    }

    @ViewBuilder private func button(_ title: LocalizedStringKey) -> some View {
        if report.isInstalling {
            ProgressView().controlSize(.mini)
        } else {
            Button(title) { Task { await toolchain.install(agent) } }
                .controlSize(.small)
        }
    }

    private var recheck: some View {
        Button { Task { await toolchain.refresh(agent) } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Re-check")
    }
}

/// What the panel keeps: a line when something is wrong, and the way to the page that fixes it.
/// Silent when the adapter is installed, current, and the CLI behind it is there — a panel that
/// reports a healthy toolchain on every launch is a panel with a paragraph nobody reads at the top.
struct AgentToolchainHint: View {
    let agent: ACPAgentDefinition

    @Environment(AgentSessionStore.self) private var store
    @Environment(BrowserState.self) private var browser

    private var report: AgentToolchain.Report { store.toolchain.report(for: agent) }

    private var trouble: LocalizedStringKey? {
        switch report.adapter {
        case .unknown, .checking: nil
        case .installed: report.update.map { _ in "\(agent.binaryName) is out of date" }
        case .installable: "\(agent.binaryName) is not installed — it runs through npx"
        case .nodeMissing: "Node.js is not installed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let trouble {
                row(trouble, symbol: "exclamationmark.circle")
            }
            if report.underlyingCLIPath == nil, report.adapter != .unknown, report.adapter != .checking {
                row("\(agent.underlyingCLI) CLI not found. \(agent.loginHint)",
                    symbol: "exclamationmark.triangle.fill")
            }
        }
        .task(id: agent.id) {
            if report.adapter == .unknown { await store.toolchain.refresh(agent) }
        }
    }

    private func row(_ text: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).lineLimit(2)
            Button("Set Up…") { browser.openBuiltIn(.configuration) }
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}
#endif
