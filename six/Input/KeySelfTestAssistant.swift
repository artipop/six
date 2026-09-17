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
    static func assistantOnly(_ browser: BrowserState, _ assistant: AssistantStore, _ focusStore: PageFocusStore) async {
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
        if let hosted = anchoredHost(in: window) {
            note("assistant: the line stands at \(hosted)")
        }
        for (code, character) in [(UInt16(44), "/"), (8, "c"), (31, "o"), (45, "n")] {
            post(flags: [], rawCode: code, characters: character, in: window)
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(300))
        note("assistant: with /con typed the line stands at \(anchoredHost(in: window) ?? "—")")
        post(flags: [], code: .returnKey, in: window)
        try? await Task.sleep(for: .milliseconds(300))
        note("assistant: /con ⏎ → \(assistant.answer?.action?.id ?? "nothing ran")")
        assistant.cancel()
        assistant.dismiss()
        try? await Task.sleep(for: .milliseconds(200))
        post(flags: [], code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("assistant: Esc → \(place(assistant, tab)), keyboard \(keyboardOwner(window))")

        // Text selected inside the field: the verbs that write, then the ones that only read.
        _ = try? await tab.page.callJavaScript("""
            const t = document.querySelector('textarea');
            t.focus();
            t.setSelectionRange(5, 9);
            """)
        try? await Task.sleep(for: .milliseconds(700))
        note("assistant: offered at a selection in the field: \(AssistantAction.offered(for: focusStore[tab.id]).map(\.id))")

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
