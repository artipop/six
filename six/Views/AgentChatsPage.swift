#if os(macOS)
import SwiftUI

/// `six://chats` — every conversation with an agent, newest first.
///
/// Everybody else keeps these in a sidebar: a column of titles fixed to the edge of the window, there
/// whether or not you are looking for a chat. Here it is a page. It opens beside what you are doing
/// (⌘⇧E), a conversation picked from it opens as a window of its own next to it, and when you have
/// what you came for both are closed like any other column.
///
/// Two lists: what six kept, and what the agent keeps for the same folder and six does not know —
/// sessions started from the agent's own CLI, or put away before six kept a history. The second
/// costs a process and a handshake, so it is asked when the page is shown and not before.
struct AgentChatsPage: View {
    let tab: BrowserTab

    @Environment(AgentSessionStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Environment(ConfigurationStore.self) private var settings
    @State private var query = ""
    @State private var everywhere = false

    private var profile: Profile { browser.profiles.first { $0.id == tab.profileID } ?? browser.selectedProfile }
    private var folder: URL { browser.workingDirectory(for: profile) }
    private var agents: [ACPAgentDefinition] { ACPAgentDefinition.builtIn + settings.customAgents }

    private var chats: [AgentChat] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return store.history.filter { chat in
            (everywhere || chat.directoryPath == folder.path)
                && words.allSatisfy { (chat.title ?? "").lowercased().contains($0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if chats.isEmpty {
                    Text(query.isEmpty ? "No chats yet" : "Nothing found")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                } else {
                    ForEach(days, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(.headline).foregroundStyle(.secondary).padding(.bottom, 4)
                            ForEach(group.chats) { chat in
                                ChatRow(chat: chat, showsFolder: everywhere) { open(chat.id) } forget: { store.forget(chat.id) }
                            }
                        }
                    }
                }
                agentSessions
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task(id: folder) { await refreshSessions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chats").font(.largeTitle.weight(.semibold))
                Spacer()
                Button("New Chat") { open(store.beginChat()) }
                .disabled(store.state == .prompting)
            }
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Folder", selection: $everywhere) {
                    Text(verbatim: profile.name).tag(false)
                    Text("All folders").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: Days

    private struct Day { let day: Date; let title: String; let chats: [AgentChat] }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: chats) { calendar.startOfDay(for: $0.updatedAt ?? $0.createdAt ?? .distantPast) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if day == .distantPast.startOfDay(calendar) { title = String(localized: "Earlier") }
            else if calendar.isDateInToday(day) { title = String(localized: "Today") }
            else if calendar.isDateInYesterday(day) { title = String(localized: "Yesterday") }
            else { title = day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
            return Day(day: day, title: title, chats: grouped[day] ?? [])
        }
    }

    // MARK: The agents' own sessions

    /// Sessions the agents have for this folder that are not in the list above, every agent in one
    /// list, newest first. Which agent a session belongs to is said on its row, not chosen up front:
    /// a person looks for a conversation, not for Codex's conversations.
    private var unknownSessions: [(agent: ACPAgentDefinition, session: ACP.SessionInfo)] {
        let known = Set(store.history.compactMap(\.sessionID))
        return agents
            .flatMap { agent in store.catalog.sessions(for: agent, in: folder).map { (agent: agent, session: $0) } }
            .filter { !known.contains($0.session.sessionId) }
            .sorted { ($0.session.updatedAt ?? "") > ($1.session.updatedAt ?? "") }
    }

    private var isLoadingSessions: Bool {
        agents.contains { store.catalog.loading.contains(AgentSessionCatalog.key(agent: $0, directory: folder)) }
    }

    @ViewBuilder private var agentSessions: some View {
        let sessions = unknownSessions
        if !sessions.isEmpty || isLoadingSessions {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Other sessions").font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    if isLoadingSessions { ProgressView().controlSize(.small) }
                }
                .padding(.bottom, 4)
                ForEach(sessions, id: \.session.sessionId) { entry in
                    SessionRow(agent: entry.agent, session: entry.session) {
                        open(store.adopt(entry.session, agent: entry.agent))
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    /// Every agent is asked; one that cannot list sessions, or is not installed, simply adds nothing.
    private func refreshSessions() async {
        for agent in agents {
            await store.catalog.refresh(agent, toolchain: store.toolchain, directory: folder)
        }
    }

    private func open(_ id: UUID) {
        browser.openBuiltIn(.chat, section: id.uuidString, in: tab.profileID)
    }
}

private extension ConfigurationStore {
    /// What a chat says it was had with. An agent since removed is still named, by its id.
    func agentName(_ id: String) -> String {
        (ACPAgentDefinition.builtIn + customAgents).first { $0.id == id }?.name ?? id
    }
}

private extension Date {
    func startOfDay(_ calendar: Calendar) -> Date { calendar.startOfDay(for: self) }
}

private struct SessionRow: View {
    let agent: ACPAgentDefinition
    let session: ACP.SessionInfo
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.title ?? String(localized: "Untitled")).lineLimit(1)
                Spacer()
                Text(agent.name).font(.caption).foregroundStyle(.secondary)
                if let date = session.updatedAt.flatMap({ try? Date($0, strategy: .iso8601) }) {
                    Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ChatRow: View {
    let chat: AgentChat
    let showsFolder: Bool
    let open: () -> Void
    let forget: () -> Void

    @Environment(AgentSessionStore.self) private var store
    @Environment(ConfigurationStore.self) private var settings
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title ?? String(localized: "Untitled")).lineLimit(1)
                    if showsFolder {
                        Text(chat.directoryPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if store.isRunning(chat.id) {
                    ProgressView().controlSize(.mini)
                } else if store.isCurrent(chat.id) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint)
                        .help("Current")
                }
                Text(agentName).font(.caption).foregroundStyle(.secondary)
                if let date = chat.updatedAt ?? chat.createdAt {
                    Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            if !store.isCurrent(chat.id) {
                Divider()
                Button("Delete", role: .destructive, action: forget)
            }
        }
    }

    private var agentName: String { settings.agentName(chat.agentID) }
}

/// `six://chat/<id>` — one conversation, and the place to go on with it.
///
/// Not a copy of the agent panel. The panel is the conversation going on right now; this is any
/// conversation, the current one included, and a message typed here makes it the current one for its
/// agent before sending — the one before it is put aside, not lost. A chat six has no transcript
/// for (one the agent listed) asks the agent for it with `session/load`, which is also what
/// continuing it would do.
struct AgentChatPage: View {
    let tab: BrowserTab

    @Environment(AgentSessionStore.self) private var store
    @Environment(ConfigurationStore.self) private var settings
    @Environment(BrowserState.self) private var browser
    @State private var input = ""

    private var id: UUID? { tab.section.flatMap(UUID.init(uuidString:)) }
    private var chat: AgentChat? { id.flatMap { store.chat($0) } }
    private var folder: URL { browser.workingDirectory(for: browser.profiles.first { $0.id == tab.profileID } ?? browser.selectedProfile) }

    var body: some View {
        Group {
            if let chat {
                VStack(spacing: 0) {
                    header(chat)
                    Divider()
                    transcript(chat)
                    if store.isRunning(chat.id), let prompt = store.permissionPrompt {
                        Divider()
                        PermissionView(prompt: prompt)
                    }
                    Divider()
                    composer(chat)
                }
                .onChange(of: chat.title, initial: true) { tab.pageTitle = chat.title ?? chat.firstPrompt }
            } else {
                Text("This chat is gone")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private func header(_ chat: AgentChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(chat.title ?? chat.firstPrompt ?? String(localized: "Untitled"))
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if store.isRunning(chat.id) {
                    Button("Stop") { store.cancel() }.controlSize(.small)
                }
                Button { browser.openBuiltIn(.chats, in: tab.profileID) } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.borderless)
                    .help("All Chats")
            }
            HStack(spacing: 6) {
                Text(settings.agentName(chat.agentID))
                if let date = chat.updatedAt ?? chat.createdAt {
                    Text("·")
                    Text(date, format: .dateTime.day().month().hour().minute())
                }
                if chat.directoryPath != folder.path {
                    Text("·")
                    Text(chat.directoryPath).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func transcript(_ chat: AgentChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.transcript.isEmpty {
                        emptyTranscript(chat)
                    }
                    ForEach(chat.transcript) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                    if store.isCurrent(chat.id), case .failed(let message) = store.state {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .onAppear { if let last = chat.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: chat.transcript.count) { if let last = chat.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    @ViewBuilder private func emptyTranscript(_ chat: AgentChat) -> some View {
        if chat.sessionID != nil {
            HStack {
                if store.isCurrent(chat.id), store.state == .starting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Load from the Agent") { load(chat) }
                        .disabled(!canContinue(chat))
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func composer(_ chat: AgentChat) -> some View {
        HStack(alignment: .bottom) {
            TextField(canContinue(chat) ? "Message…" : "In another folder", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onSubmit { send(chat) }
            Button("Send") { send(chat) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .disabled(!canContinue(chat))
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// Going on with a chat needs its folder to be the one the agent works in, and no other turn
    /// running: making this one current would cut that turn off.
    private func canContinue(_ chat: AgentChat) -> Bool {
        chat.directoryPath == store.workingDirectory.path
            && (store.state != .prompting || store.isRunning(chat.id))
            && store.state != .starting
    }

    private func send(_ chat: AgentChat) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isRunning(chat.id), store.open(chat.id) else { return }
        input = ""
        store.send(text)
    }

    private func load(_ chat: AgentChat) {
        guard store.open(chat.id) else { return }
        store.disconnect()
        Task { await store.connect() }
    }
}
#endif
