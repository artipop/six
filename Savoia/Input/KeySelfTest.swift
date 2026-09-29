#if os(macOS)
import AppKit
import WebKit

/// `SAVOIA_KEY_SELFTEST=1`: what the table answers, for every chord in it, in every context there is —
/// a row per chord, a column per context — and then the same keys posted into the app's own queue.
enum KeySelfTest {
    static func run() {
        let contexts: [(String, KeyContext)] = [
            ("page", KeyContext(window: .main)),
            ("empty field", KeyContext(window: .main, field: .init(kind: .singleLine, hasTextBefore: false, hasTextAfter: false))),
            ("typed-in field", KeyContext(window: .main, field: .init(kind: .singleLine, hasTextBefore: true, hasTextAfter: true))),
            ("document", KeyContext(window: .main, field: .init(kind: .multiLine, hasTextBefore: true, hasTextAfter: true))),
            ("sheet", KeyContext(window: .elsewhere)),
            ("ring open", KeyContext(window: .main, isSwitching: true))
        ]
        let chords: [(String, NSEvent.ModifierFlags, KeyCode, String)] = [
            ("⌥⇧T", [.option, .shift], .t, "t"),
            ("⌥⇧H", [.option, .shift], .h, "h"),
            ("⌥⇧P", [.option, .shift], .p, "p"),
            ("⌥⇧P (ru)", [.option, .shift], .p, "з"),
            ("⌘⇧C", [.command, .shift], .c, "c"),
            ("⌘⇧C (ru)", [.command, .shift], .c, "с"),
            ("⌃Tab", .control, .tab, "\t"),
            ("⌃⇧Tab", [.control, .shift], .tab, "\t"),
            ("⌃→", .control, .rightArrow, ""),
            ("⌃←", .control, .leftArrow, ""),
            ("Esc", [], .escape, "\u{1b}"),
            ("⌃Esc", .control, .escape, "\u{1b}"),
            ("↩", [], .returnKey, "\r"),
            ("⌤", [], .keypadEnter, "\r")
        ]
        var out = "[Savoia] keys: what the table answers — «page:» is offered to a focused page first, and answers only if it comes back\n"
        out += pad("") + contexts.map { pad($0.0) }.joined() + "\n"
        for (name, flags, code, characters) in chords {
            let event = self.event(flags: flags, code: code, characters: characters)
            out += pad(name)
            for (_, context) in contexts {
                out += pad(answer(for: event, in: context))
            }
            out += "\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// What `KeyRouter.handle` would decide, said in one word.
    private static func answer(for event: NSEvent, in context: KeyContext) -> String {
        guard let binding = KeyBindings.all.first(where: { $0.matches(event, in: context) }) else { return "—" }
        if binding.yieldsToCaret(in: context) { return "caret" }
        let offered = binding.precedence == .pageFirst && context.field == nil && context.window == .main
        return (offered ? "page:" : "") + label(binding.action)
    }

    private static func label(_ action: KeyAction) -> String {
        switch action {
        case .translateSelection: return "translate"
        case .highlightSelection: return "highlight"
        case .pictureInPicture: return "picture"
        case .copyAddress: return "copy address"
        case .stepSwitcher(let step): return step < 0 ? "ring ←" : "ring →"
        case .walkSwitcher(let step): return step < 0 ? "card ←" : "card →"
        case .landSwitcher: return "land"
        case .cancelSwitcher: return "cancel"
        }
    }

    /// The other half: keys posted into Savoia's own event queue (`NSApp.postEvent` needs no
    /// Accessibility), through the real router. Leaves the tabs as it found them.
    static func live(_ browser: BrowserState) async {
        NSApp.activate()
        var candidate: NSWindow?
        for _ in 0..<25 {
            candidate = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first { $0.canBecomeKey && $0.contentView != nil }
            if candidate != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let window = candidate else {
            note("no window to post into; have \(NSApp.windows.map { "\(type(of: $0)) visible:\($0.isVisible)" })")
            return
        }
        window.makeKeyAndOrderFront(nil)
        note("window \(window.windowNumber) \(type(of: window)) — sheet: \(window.isSheet), parent: \(window.parent != nil)")

        let first = browser.newTabAtEnd()
        let second = browser.newTabAtEnd()
        try? await Task.sleep(for: .milliseconds(400))
        note("tabs: \(selection(browser))")

        // The ring is opened by the key alone — nothing posts a `flagsChanged`, so ⌃ never comes up
        // and the ring stays open long enough to be read. The caret is still in the address field,
        // where an arrow would otherwise be the caret's.
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        let ringCard = browser.switcher.index
        note("⌃⇥ → ring \(browser.switcher.ring.count), lands on \(browser.switcher.selection == first.id ? "the tab before" : "another")")
        post(flags: .control, code: .rightArrow, in: window)
        try? await Task.sleep(for: .milliseconds(250))
        let steppedRight = browser.switcher.index
        post(flags: .control, code: .leftArrow, in: window)
        try? await Task.sleep(for: .milliseconds(250))
        note("⌃→ ⌃← over the ring, caret in \(keyboard(NSApp.keyWindow ?? NSApp.mainWindow))"
            + " → card \(ringCard) → \(steppedRight) → \(browser.switcher.index)")
        post(flags: .control, code: .escape, in: window)
        try? await Task.sleep(for: .milliseconds(250))
        note("⌃Esc → ring open \(browser.switcher.isOpen), \(selection(browser))")

        browser.closeTab(second.id, remembering: false)
        browser.closeTab(first.id, remembering: false)
        try? await Task.sleep(for: .milliseconds(300))
        await menuKeys(browser, in: window)
    }

    /// The `⌘` keys, which are menu items rather than table rows — here for the same doubt the
    /// table was written to settle, pointing the other way.
    ///
    /// A key equivalent is offered to the key window first and to the main menu second, so a focused
    /// `WKWebView` stands in front of every menu item Savoia has.
    /// Whether it also keeps `⌘[` and `⌘R` is not a question reading its source answers, so the page
    /// is made first responder **by hand** for the second round — without that this measures only
    /// the easy case, where the address field has the focus and nothing is competing for the key.
    ///
    /// `about:blank` and a fragment on it: two history entries, no network, and a back list that
    /// says plainly whether the item ran. Reload leaves no trace in a back list, so the page is
    /// marked from the inside instead and the mark is looked for again afterwards — a reload is the
    /// mark being gone.
    ///
    /// The two controls go **last**, and that ordering is the whole reason this reads clearly.
    /// `⌘T` opens a window and takes the selection with it, so a control pressed early leaves every
    /// key after it aimed at a fresh window with no history — which looked exactly like WebKit
    /// swallowing the key, and cost a round of believing it had.
    private static func menuKeys(_ browser: BrowserState, in window: NSWindow) async {
        guard let blank = URL(string: "about:blank") else { return }
        let tab = browser.newTab(url: blank)
        try? await Task.sleep(for: .milliseconds(700))
        tab.load(URL(string: "about:blank#two") ?? blank)
        try? await Task.sleep(for: .milliseconds(700))

        for round in ["field focused", "page focused"] {
            if round == "page focused", let page = webView(in: window) {
                _ = window.makeFirstResponder(page)
            }
            note("\(round) — first responder \(responder(window)), \(describe(tab))")
            for (name, code, characters) in [("⌘[", UInt16(33), "["), ("⌘]", UInt16(30), "]")] {
                post(flags: .command, rawCode: code, characters: characters, in: window)
                try? await Task.sleep(for: .milliseconds(500))
                note("\(name) → \(describe(tab))")
            }
            _ = try? await tab.page.callJavaScript("window.__savoia = 1")
            post(flags: .command, rawCode: 15, characters: "r", in: window)
            try? await Task.sleep(for: .milliseconds(700))
            let mark = try? await tab.page.callJavaScript("return window.__savoia")
            note("⌘R → the page's mark is \((mark as? Int).map(String.init) ?? "gone"), \(describe(tab))")
        }

        // ⌘⇧C, measured the only way it can be: press it and look in the pasteboard. It is a table
        // row rather than a menu item, so this is asking whether the router beats the focused page
        // to a ⌘ chord — the same question `⌘[` above asks from the other side.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("nothing was copied", forType: .string)
        post(flags: [.command, .shift], code: .c, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("⌘⇧C → pasteboard \(NSPasteboard.general.string(forType: .string) ?? "—")")

        // The control, and it goes last because it takes the selection with it: a menu key whose
        // effect is not in doubt, so that a silent round above can be told apart from a posting that
        // never arrived. Without it, "the item did nothing" and "the key never reached a menu" look
        // identical, and they were confused here once already.
        let before = browser.tabs.count
        post(flags: .command, rawCode: 17, characters: "t", in: window)
        try? await Task.sleep(for: .milliseconds(600))
        note("⌘T (the control) → windows \(before) → \(browser.tabs.count)")
        if let opened = browser.selectedTab, opened.id != tab.id { browser.closeTab(opened.id) }
        browser.closeTab(tab.id)
    }

    private static func describe(_ tab: BrowserTab) -> String {
        "\(tab.currentURL?.absoluteString ?? "—"), back \(tab.canGoBack), forward \(tab.canGoForward)"
    }

    /// Who has the keyboard, and — when it is a page — whose it is (`WebViewResponder`).
    private static func keyboard(_ window: NSWindow?) -> String {
        guard let window else { return "no key window" }
        guard let responder = window.firstResponder else { return "none" }
        let name = String(describing: type(of: responder))
        guard let view = responder as? NSView else { return name }
        let owner = WebViewResponder.shared.owner(of: responder)
        let owned = owner.map { String($0.uuidString.prefix(8)) } ?? "unknown"
        return "\(name) \(Int(view.bounds.width))pt \(owned)"
    }

    private static func responder(_ window: NSWindow) -> String {
        window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }

    /// The topmost `WKWebView` in the window, which is what SwiftUI's `WebView` is underneath.
    private static func webView(in window: NSWindow) -> NSView? {
        var stack = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if view is WKWebView { return view }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Which tab is selected, and who has the keyboard.
    static func selection(_ browser: BrowserState) -> String {
        let order = browser.tabOrder()
        let position = browser.selectedTabID.flatMap { order.firstIndex(of: $0) }
        return "tab \(position.map { $0 + 1 } ?? 0)/\(order.count), keys \(keyboard(NSApp.keyWindow ?? NSApp.mainWindow))"
    }

    static func post(flags: NSEvent.ModifierFlags, code: KeyCode, in window: NSWindow) {
        post(flags: flags, rawCode: code.rawValue, characters: characters(for: code), in: window)
    }

    /// The menu's keys are not the table's keys, and `KeyCode` is the table's — a `case r` there
    /// would be a name nothing in `KeyBindings` ever says. They are posted by number instead.
    static func post(flags: NSEvent.ModifierFlags, rawCode: UInt16, characters: String,
                     ignoringModifiers: String? = nil, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                                           isARepeat: false, keyCode: rawCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// What AppKit itself puts in `characters` for these keys. An arrow carries a function-key
    /// scalar, not an empty string, and a text view handed an empty one is a text view that crashes.
    private static func characters(for code: KeyCode) -> String {
        let scalar: Int
        switch code {
        case .leftArrow: scalar = NSLeftArrowFunctionKey
        case .rightArrow: scalar = NSRightArrowFunctionKey
        case .upArrow: scalar = NSUpArrowFunctionKey
        case .downArrow: scalar = NSDownArrowFunctionKey
        case .home: scalar = NSHomeFunctionKey
        case .end: scalar = NSEndFunctionKey
        case .escape: return "\u{1b}"
        case .tab: return "\t"
        case .returnKey, .keypadEnter: return "\r"
        case .c: return "c"
        case .h: return "h"
        case .p: return "p"
        case .t: return "t"
        }
        return String(UnicodeScalar(UInt32(scalar)) ?? " ")
    }

    static func note(_ message: String) {
        Log.info(.keys, message)
    }

    private static func event(flags: NSEvent.ModifierFlags, code: KeyCode, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code.rawValue)!
    }

    private static func pad(_ text: String) -> String {
        text.padding(toLength: max(16, text.count + 1), withPad: " ", startingAt: 0)
    }
}
#endif
