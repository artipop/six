#if os(macOS)
import AppKit
import WebKit

/// The line asked for, and then Tab on a start page: the ⌘E line is tucked away but stays in the view hierarchy,
/// and a field that is merely invisible is still in the window's key-view loop — Tab walked into it
/// and a focused line is a shown one. Each line names the field that holds the caret by its
/// placeholder, which is the one thing that tells the address field from the ⌘E line from outside.
///
/// `SIX_KEY_SELFTEST=assistant` runs this alone. It needs the assistant switched on, or there is no
/// line to walk into and the Tab half passes for the wrong reason — the first line says which.
extension KeySelfTest {
    static func assistantOnly(_ browser: BrowserState, _ assistant: AssistantStore, _ focusStore: PageFocusStore,
                              _ agents: AgentSessionStore) async {
        NSApp.activate()
        for _ in 0..<100 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.contentView != nil }) else {
            return note("assistant: no window")
        }
        window.makeKeyAndOrderFront(nil)
        let tab = browser.newTab()
        try? await Task.sleep(for: .milliseconds(800))
        note("assistant: AI \(ConfigurationStore.shared?.isAIEnabled == true ? "on" : "OFF"), start page, caret \(caret(window))")
        // Asked for first, from the address field — the control that says the line can still be
        // summoned at all once it is out of the key-view loop. Not through a posted ⌘E: that is a
        // menu item, and a posted one does not reach the menu here.
        assistant.summonLine(in: tab)
        try? await Task.sleep(for: .milliseconds(500))
        note("assistant: summoned → \(place(assistant)), caret \(caret(window))")
        // The menu item behind ⌘E, pressed twice: the second press puts the line away. Performed on
        // the item itself, because a posted ⌘E does not reach the menu here (see above).
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(500))
        note("assistant: menu ⌘E → caret \(caret(window))")
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(500))
        note("assistant: menu ⌘E again → caret \(caret(window))")
        assistant.summonLine(in: tab)
        try? await Task.sleep(for: .milliseconds(500))
        // A slash narrows the verbs and Return runs the first left. On a start page only the page's
        // verbs apply, so `/sum` has one answer. It is cancelled at once: the question is whether the
        // right verb started, not what the model makes of a start page.
        for (code, character) in [(UInt16(44), "/"), (1, "s"), (32, "u"), (46, "m")] {
            post(flags: [], rawCode: code, characters: character, in: window)
            try? await Task.sleep(for: .milliseconds(120))
        }
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        note("assistant: /sum ⏎ → \(assistant.answer?.action?.id ?? "nothing ran"), caret \(caret(window))")
        assistant.cancel()
        assistant.dismiss()
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        note("assistant: Esc → caret \(caret(window))")
        _ = window.makeFirstResponder(nil)
        browser.closeTab(tab.id)
        let second = browser.newTab()
        try? await Task.sleep(for: .milliseconds(800))
        note("assistant: a fresh start page, caret \(caret(window))")
        for press in 1...3 {
            post(flags: [], code: .tab, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            note("assistant: ⇥ \(press) → caret \(caret(window))")
        }
        _ = window.makeFirstResponder(nil)
        browser.closeTab(second.id)
        await fieldVerbs(browser, assistant, focusStore, in: window)
        // The line with a model that cannot answer: the row of verbs is replaced by what is missing,
        // so Return over it runs nothing. The choice is put back at once — this is the dev profile's
        // own setting, and a test that changed it would be a test that moved the furniture.
        let chosen = assistant.settings.model
        assistant.settings.model = .claudeSonnet
        let unconfigured = browser.newTab(url: URL(string: "about:blank"))
        try? await Task.sleep(for: .milliseconds(1000))
        _ = try? await unconfigured.page.callJavaScript("""
            const t = document.createElement('textarea');
            t.value = 'Dear team';
            document.body.appendChild(t);
            t.focus();
            t.setSelectionRange(9, 9);
            """)
        try? await Task.sleep(for: .milliseconds(700))
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(700))
        let trouble = assistant.settings.trouble.map { String(localized: $0.message) } ?? "ready"
        note("assistant: with \(assistant.settings.model.title) unconfigured the line says «\(trouble)»")
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("assistant: ⏎ where the verbs were → \(assistant.answer?.action?.id ?? "nothing ran")")
        assistant.cancel()
        assistant.dismiss()
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        browser.closeTab(unconfigured.id)
        assistant.settings.model = chosen
        note("assistant: the model is back to \(assistant.settings.model.title)")

        // What each model would say if it were asked now. The line says this where the verbs would
        // be, with a way to `six://configuration` for the half a person can put right.
        for choice in ModelChoice.allCases {
            let trouble = assistant.settings.trouble(for: choice)
            let said = trouble.map { String(localized: $0.message) } ?? "ready"
            note("assistant: \(choice.title) — \(said)\(trouble?.isConfiguration == true ? " (offers Set Up…)" : "")")
        }
        // The adapters, which are not thin shims: each carries its own copy of the CLI it drives,
        // so an old one answers today's models with "requires a newer version" while the CLI on the
        // machine is current. The panel says the version and offers Update; this says what it sees.
        for agent in ACPAgentDefinition.builtIn {
            await agents.toolchain.refresh(agent)
            let report = agents.toolchain.report(for: agent)
            let update = report.update.map { " — \($0.to) is out" } ?? ""
            note("assistant: \(agent.binaryName) \(report.installedVersion ?? "not installed")\(update)")
        }
        note("assistant: done")
    }

    /// ⌘E over a page that has something pointed at: the line hangs on it instead of rising at the
    /// bottom. A caret in a `<textarea>` first — the caret has to outlive the line taking the
    /// keyboard, `/con` has to find Continue Writing (which a start page would not offer), and Esc has
    /// to give the keyboard back to the page. Then a selection, with ⌘E pressed twice.
    private static func fieldVerbs(_ browser: BrowserState, _ assistant: AssistantStore,
                                   _ focusStore: PageFocusStore, in window: NSWindow) async {
        guard let blank = URL(string: "about:blank") else { return }
        let tab = browser.newTab(url: blank)
        try? await Task.sleep(for: .milliseconds(1200))
        _ = try? await tab.page.callJavaScript("""
            document.body.innerHTML = '<p id="p">The rail is a workspace, and workspaces stack.</p>';
            const t = document.createElement('textarea');
            t.value = 'Dear team, the release is';
            t.style.cssText = 'width: 500px; height: 120px; margin-top: 40px';
            document.body.appendChild(t);
            t.focus();
            t.setSelectionRange(t.value.length, t.value.length);
            """)
        try? await Task.sleep(for: .milliseconds(800))
        let rect = focusStore[tab.id].rect.integral
        note("assistant: textarea → focus \(focusStore[tab.id].kind) at \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(600))
        note("assistant: menu ⌘E → \(place(assistant, tab)), caret \(caret(window)), page focus still \(focusStore[tab.id].kind)")
        note("assistant: offered at a caret: \(AssistantAction.offered(for: assistant.subject(in: tab.id)).map(\.id))")
        note("assistant: the row stands at \(anchoredHost(in: window) ?? "—"), keyboard \(keyboardOwner(window))")
        // The row, walked and pressed: → moves off Continue Writing onto Draft a Reply, and Return
        // runs what it is on. Nothing is typed, which is the point of the row.
        post(flags: [], code: .rightArrow, in: window)
        try? await Task.sleep(for: .milliseconds(250))
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("assistant: → ⏎ over the row → \(assistant.answer?.action?.id ?? "nothing ran")")
        assistant.cancel()
        assistant.dismiss()
        try? await Task.sleep(for: .milliseconds(200))
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(400))

        // And the other way out of the row: a character turns it into the field, with the character
        // already in it. `/` then narrows the verbs as it does at the bottom.
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(600))
        note("assistant: ⌘E again → \(place(assistant, tab)), keyboard \(keyboardOwner(window))")
        for (code, character) in [(UInt16(44), "/"), (8, "c"), (31, "o"), (45, "n")] {
            post(flags: [], rawCode: code, characters: character, in: window)
            try? await Task.sleep(for: .milliseconds(150))
        }
        note("assistant: typed over the row → caret \(caret(window)), the line stands at \(anchoredHost(in: window) ?? "—")")
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("assistant: /con ⏎ → \(assistant.answer?.action?.id ?? "nothing ran")")
        assistant.cancel()
        assistant.dismiss()
        try? await Task.sleep(for: .milliseconds(200))
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("assistant: Esc → \(place(assistant, tab)), keyboard \(keyboardOwner(window))")

        // Text selected inside the field. The line must be about the selection and not about the
        // field — asking collapses the field's own selection to a caret, which is what the page says
        // by the time the row is drawn — and the page is asked to put the selection back.
        _ = try? await tab.page.callJavaScript("""
            const t = document.querySelector('textarea');
            t.focus();
            t.setSelectionRange(5, 9);
            """)
        try? await Task.sleep(for: .milliseconds(700))
        note("assistant: selected «team» in the field → focus \(focusStore[tab.id].kind)")
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(700))
        let subject = assistant.subject(in: tab.id)
        note("assistant: menu ⌘E → the line is about the \(subject.kind) «\(subject.text)»")
        note("assistant: offered at a selection in the field: \(AssistantAction.offered(for: subject).map(\.id))")
        let range = (try? await tab.page.callJavaScript("""
            const t = document.querySelector('textarea');
            return t.selectionStart + '-' + t.selectionEnd;
            """)) as? String
        note("assistant: the page reports \(focusStore[tab.id].kind) and the field holds \(range ?? "?")")
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(400))

        _ = try? await tab.page.callJavaScript("""
            document.activeElement.blur();
            const range = document.createRange();
            range.selectNodeContents(document.getElementById('p'));
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            """)
        try? await Task.sleep(for: .milliseconds(700))
        note("assistant: selection → focus \(focusStore[tab.id].kind)")
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(600))
        let kept = (try? await tab.page.callJavaScript("return String(window.getSelection())")) as? String
        note("assistant: menu ⌘E → \(place(assistant, tab)), caret \(caret(window)), the line is about the \(assistant.subject(in: tab.id).kind) «\(assistant.subject(in: tab.id).text.prefix(20))», the page still has «\(kept ?? "?")»")
        note("assistant: the line stands at \(anchoredHost(in: window) ?? "—")")
        note("assistant: offered at a selection: \(AssistantAction.offered(for: assistant.subject(in: tab.id)).map(\.id))")
        note("assistant: keyboard \(keyboardOwner(window))")
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("assistant: ⏎ over the row at a selection → \(assistant.answer?.action?.id ?? "nothing ran")")
        assistant.cancel()
        assistant.dismiss()
        try? await Task.sleep(for: .milliseconds(200))
        pressAssistantItem()
        try? await Task.sleep(for: .milliseconds(600))
        note("assistant: menu ⌘E again → \(place(assistant, tab)), keyboard \(keyboardOwner(window))")
        browser.closeTab(tab.id)
    }

    private static func place(_ assistant: AssistantStore, _ tab: BrowserTab? = nil) -> String {
        switch assistant.line {
        case nil: "away"
        case .bottom: "bottom"
        case .page(let id): id == tab?.id ? "at the page's focus" : "at another page"
        }
    }

    private static func keyboardOwner(_ window: NSWindow) -> String {
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }

    /// The hosting view the anchored line lives in, by its frame in the window — the one fact about
    /// where it went that can be read without a screenshot.
    private static func anchoredHost(in window: NSWindow) -> String? {
        guard let field = (window.firstResponder as? NSText)?.delegate as? NSView else { return nil }
        var view: NSView? = field
        while let current = view, !String(describing: type(of: current)).hasPrefix("NSHostingView") {
            view = current.superview
        }
        guard let host = view else { return nil }
        let frame = host.convert(host.bounds, to: nil).integral
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) in a window \(Int(window.frame.height)) tall"
    }

    private static func pressAssistantItem() {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == "e", item.keyEquivalentModifierMask == .command { return (menu, index) }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let (menu, index) = find(main) else { return note("assistant: no ⌘E item") }
        menu.update()
        note("assistant: pressing «\(menu.items[index].title)», enabled \(menu.items[index].isEnabled)")
        menu.performActionForItem(at: index)
    }

    private static func caret(_ window: NSWindow) -> String {
        guard let responder = window.firstResponder else { return "none" }
        let field = (responder as? NSText)?.delegate as? NSTextField ?? responder as? NSTextField
        guard let field else { return String(describing: type(of: responder)) }
        return "field «\(field.placeholderString ?? field.placeholderAttributedString?.string ?? "")»"
    }
}
#endif
