#if os(macOS)
import AppKit
import WebKit

/// `SAVOIA_UPLOAD_SELFTEST=<scripts/agent-stand/consent-agent.py>` — two files given to a page by an
/// agent that asks first and by one that does not; each round says who was asked and what the page got.
enum UploadConsentSelfTest {
    private static let page = """
        <!doctype html><title>Upload selftest</title>
        <input type=file id=f style="position:fixed;left:40px;top:40px"
               onchange="(window.r = window.r || []).push(...[...this.files].map(f => f.name))">
        """

    static func run(_ browser: BrowserState, _ agents: AgentSessionStore, agentScript: String) async {
        func say(_ line: String) { Log.info(.ui, "upload selftest: \(line)") }
        try? await Task.sleep(for: .milliseconds(600))
        let folder = FileManager.default.temporaryDirectory.appending(path: "upload-selftest-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = ["one.txt", "two.txt"].map { folder.appending(path: $0) }
        for file in files { try? Data(file.lastPathComponent.utf8).write(to: file) }

        let tab = browser.newTab(url: URL(string: "about:blank"))
        await tab.loadSettled()
        tab.page.loadHTMLString(page, baseURL: URL(string: "https://upload.selftest/"))
        try? await Task.sleep(for: .seconds(1))
        NSApp.activate()
        tab.livePage?.window?.makeKeyAndOrderFront(nil)

        agents.agent = ACPAgentDefinition(
            id: "consent-stand", name: "Consent stand", command: "/usr/bin/python3", arguments: [agentScript],
            npmPackage: "", binaryName: "", underlyingCLI: "", loginHint: AttributedString(""))
        // An agent starts in the login shell's environment, where `Savoia --mcp` would find another Savoia.
        for name in ["CFFIXED_USER_HOME", "SAVOIA_MCP_SOCKET"] {
            agents.agent.environment[name] = ProcessInfo.processInfo.environment[name]
        }

        /// One turn, with a person at the card and at the bar: "always" where it is offered, and the
        /// bar's answers in the order given.
        func round(_ mode: String, bar: [Bool], expecting: (cards: Int, bars: Int, page: String)) async {
            _ = try? await tab.callWithoutGesture("window.r = []; document.getElementById('f').value = ''", in: .page)
            var cards = 0, bars = 0, offered: [String] = [], asked: [String] = [], answers = bar
            let person = Task { @MainActor in
                var seenCard: UUID?, seenBar: UUID?
                while !Task.isCancelled {
                    if let prompt = agents.permissionPrompt, prompt.id != seenCard {
                        seenCard = prompt.id
                        cards += 1
                        let options = prompt.request.options
                        offered.append(options.map(\.kind.rawValue).joined(separator: "/"))
                        if let option = options.first(where: { $0.kind == .allowAlways }) ?? options.first(where: { $0.kind == .allowOnce }) {
                            agents.resolvePermission(with: option)
                        }
                    }
                    if let question = browser.permissions?.question(for: tab.id), question.id != seenBar {
                        seenBar = question.id
                        bars += 1
                        asked.append(question.prompt)
                        browser.permissions?.answer(answers.isEmpty ? false : answers.removeFirst(), for: tab.id)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            var said = ""
            let outcome = await agents.prompt(([mode] + files.map(\.path)).joined(separator: "\n")) { update in
                if case .text(let text) = update { said = text }
            }
            person.cancel()
            let got = ((try? await tab.callWithoutGesture("return (window.r || []).join(',')", in: .page)) as? String) ?? "unread"
            let ok = cards == expecting.cards && bars == expecting.bars && got == expecting.page
            say("\(ok ? "ok" : "FAILED") — \(mode): \(cards) cards [\(offered.joined(separator: "; "))], \(bars) bars \(asked), "
                + "page got \"\(got)\" (expected \(expecting.cards) cards, \(expecting.bars) bars, \"\(expecting.page)\"); turn \(outcome)")
            for line in said.split(separator: "\n") { say("  agent: \(line)") }
        }

        await round("card", bar: [], expecting: (2, 0, "one.txt,two.txt"))
        await round("nocard", bar: [false, true], expecting: (0, 2, "two.txt"))
        say("done")
    }
}
#endif
