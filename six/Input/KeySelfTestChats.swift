#if os(macOS)
import AppKit

/// `SIX_KEY_SELFTEST=chats`: the arrows over the chats a `/` finds in the ⌘E line, pressed for real.
/// At the bottom of the row the line grows up, so the list stands above the field: ↑ goes in at the
/// row nearest the field, the next ↑ one further, ↓ one back. Each run says which chat Return picked
/// against the one the arrows should have landed on; nothing is asked of the agent.
extension KeySelfTest {
    static func chatsOnly(_ browser: BrowserState, _ assistant: AssistantStore, _ agents: AgentSessionStore) async {
        NSApp.activate()
        for _ in 0..<100 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.contentView != nil }) else {
            return note("chats: no window")
        }
        window.makeKeyAndOrderFront(nil)
        let tab = browser.newTab()
        try? await Task.sleep(for: .milliseconds(800))
        let matches = agents.chats(matching: "")
        note("chats: \(matches.count) offered for a bare /: \(matches.map { $0.title ?? "?" })")
        guard matches.count >= 2 else { return note("chats: need two chats in this folder") }
        let last = matches.count - 1
        let runs: [(String, [KeyCode], AgentChat)] = [
            ("↑", [.upArrow], matches[last]),
            ("↑↑", [.upArrow, .upArrow], matches[last - 1]),
            ("↑↑↓", [.upArrow, .upArrow, .downArrow], matches[last]),
        ]
        for (name, keys, expected) in runs {
            assistant.closeLine()
            try? await Task.sleep(for: .milliseconds(300))
            assistant.summonLine(in: tab)
            try? await Task.sleep(for: .milliseconds(600))
            post(flags: [], rawCode: 44, characters: "/", in: window)
            try? await Task.sleep(for: .milliseconds(300))
            for key in keys {
                post(flags: [], code: key, in: window)
                try? await Task.sleep(for: .milliseconds(200))
            }
            post(flags: [], code: .returnKey, in: window)
            try? await Task.sleep(for: .milliseconds(400))
            let picked = assistant.continuedChat
            note("chats: / \(name) ⏎ → \(picked?.title ?? "nothing") \(picked?.id == expected.id ? "✓" : "✗ expected \(expected.title ?? "?")")")
            assistant.stopContinuingChat()
        }
        assistant.closeLine()
        browser.closeTab(tab.id)
    }
}
#endif
