#if os(macOS)
import Foundation

/// `SIX_CHATS_SELFTEST=<prompt>`: the history end to end against a real agent. One short turn in a
/// new chat, the chat put aside, the agent asked what sessions it keeps, the chat brought back, and
/// one session six did not know taken in and replayed with `session/load`. Every step is a line in
/// the log (`Log`, category acp), so the run can be read without a window.
extension AgentSessionStore {
    func chatsSelfTest(prompt text: String, browser: BrowserState) async {
        func note(_ line: String) { Log.info(.acp, "chats selftest: \(line)") }
        try? await Task.sleep(for: .seconds(2))
        note("start: agent \(agent.id), folder \(workingDirectory.path), \(history.count) in history, \(past.count) past")

        let id = beginChat()
        browser.openBuiltIn(.chat, section: id.uuidString)
        let outcome = await prompt(text)
        let first = chat(id)
        note("turn: \(outcome), \(first?.transcript.count ?? -1) items, session \(first?.sessionID ?? "none"), title \(first?.title ?? "none")")

        startNewChat()
        let file = archive.folder.appending(path: "\(id.uuidString).json")
        note("put aside: in past \(past.contains { $0.id == id }), current \(isCurrent(id)), file \(FileManager.default.fileExists(atPath: file.path)), summary title \(past.first { $0.id == id }?.title ?? "none")")

        await catalog.refresh(agent, toolchain: toolchain, directory: workingDirectory)
        let listed = catalog.sessions(for: agent, in: workingDirectory)
        let key = AgentSessionCatalog.key(agent: agent, directory: workingDirectory)
        note("session/list: \(listed.count) sessions, ours listed \(listed.contains { $0.sessionId == first?.sessionID }), unsupported \(catalog.unsupported.contains(agent.id)), error \(catalog.errors[key] ?? "none")")

        let reopened = open(id)
        note("open: \(reopened), current \(isCurrent(id)), \(chat(id)?.transcript.count ?? -1) items, file left \(FileManager.default.fileExists(atPath: file.path))")

        // Six forgets the chat it just made, so the agent's copy is the only one left: that is the
        // session a person would find under "Other sessions" and take back.
        startNewChat()
        forget(id)
        note("forgotten: in history \(history.contains { $0.id == id })")
        let known = Set(history.compactMap(\.sessionID))
        if let stranger = listed.first(where: { $0.sessionId == first?.sessionID && !known.contains($0.sessionId) }) {
            let adopted = adopt(stranger, agent: agent)
            let opened = open(adopted)
            disconnect()
            await connect()
            note("adopt \(stranger.sessionId) '\(stranger.title ?? "")': open \(opened), state \(state), replayed \(chat(adopted)?.transcript.count ?? -1) items")
        } else {
            note("adopt: no session six did not know")
        }
        browser.openBuiltIn(.chats)
        note("done: \(history.count) in history, \(past.count) past")
    }
}
#endif

#if os(macOS)
/// `SIX_LINE_CHATS_SELFTEST=<prompt>`: the ⌘E line against the history. Two summonses, two chats;
/// a follow-up while the line stands, the same chat.
extension AssistantStore {
    func lineChatsSelfTest(prompt text: String, agents: AgentSessionStore, browser: BrowserState) async {
        func note(_ line: String) { Log.info(.acp, "line chats selftest: \(line)") }
        func waitForAnswer() async {
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<120 where answer?.isRunning == true { try? await Task.sleep(for: .milliseconds(500)) }
        }
        func current() -> String {
            let chat = agents.chats[agents.currentChatKey]
            return "\(chat?.id.uuidString.prefix(8) ?? "none") with \(chat?.transcript.count ?? 0) items, session \(chat?.sessionID?.prefix(8) ?? "none")"
        }
        try? await Task.sleep(for: .seconds(2))
        let tab = browser.selectedTab
        let before = agents.history.count
        note("start: \(before) in history, current \(current())")
        summonLine(in: tab)
        ask(text, about: tab)
        await waitForAnswer()
        note("first summons: \(current())")
        ask(text, about: tab)
        await waitForAnswer()
        note("follow-up, line up: \(current())")
        closeLine()
        summonLine(in: tab)
        ask(text, about: tab)
        await waitForAnswer()
        note("second summons: \(current()), history \(before) → \(agents.history.count)")
        closeLine()

        // Found from the line: `/` and a word of the first chat's title, then a question into it.
        summonLine(in: tab)
        let found = agents.chats(matching: "pong")
        guard let target = found.last else { return note("find: nothing matches 'pong'") }
        let targetBefore = agents.chat(target.id)?.transcript.count ?? 0
        continueChat(target.id)
        note("find: \(found.count) match, picked \(target.id.uuidString.prefix(8)), recalled «\(answer?.title ?? "")» → «\(answer?.text.prefix(40) ?? "")»")
        let historyBefore = agents.history.count
        ask(text, about: tab)
        await waitForAnswer()
        note("continued: current \(current()), picked chat \(targetBefore) → \(agents.chat(target.id)?.transcript.count ?? -1) items, history \(historyBefore) → \(agents.history.count)")
        closeLine()
    }
}
#endif
