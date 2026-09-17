#if os(macOS)
import AppKit
import WebKit

/// `.pageFirst`, measured: which keys a page keeps and which it hands back to the rail.
///
/// `SIX_KEY_SELFTEST=page` runs this alone; the full self-test runs it before the menu keys. Every
/// line says what the page saw and what six did, because the two halves are separate questions and
/// either can be wrong on its own: a key six answered *and* the page answered is a double action,
/// a key nobody answered is a dead one.
///
/// One page, rewritten between cases rather than a window per case — the page is the variable and
/// the rail around it is not. What it lists was the throwaway probe that settled the design: the
/// redelivery of an unhandled key passes back through the local monitor, a page that can scroll
/// keeps `⌥↓` even at its bottom edge, and an empty `<input>` keeps `⌥←` although nothing moves.
extension KeySelfTest {
    static func pageOnly(_ browser: BrowserState) async {
        NSApp.activate()
        for _ in 0..<100 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(300)) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && $0.contentView != nil }) else {
            return note("page first: no window")
        }
        window.makeKeyAndOrderFront(nil)
        note("page first: six is \(NSApp.isActive ? "" : "NOT ")the front app")
        await pageFirst(browser, in: window)
        note("page first: done")
    }

    static func pageFirst(_ browser: BrowserState, in window: NSWindow) async {
        guard let blank = URL(string: "about:blank") else { return }
        // A window to the left to walk to, so a ⌥← six answers is visible as the selection moving.
        let left = browser.newTab(url: blank)
        let tab = browser.newTab(url: blank)
        try? await Task.sleep(for: .milliseconds(1500))
        guard let web = WebViewResponder.shared.webView(for: tab.id) else {
            browser.closeTab(tab.id); browser.closeTab(left.id)
            return note("page first: the test page has no web view")
        }

        let tall = "<div style='height:6000px'>tall</div>"
        let field = "<input id=f value='hello world'>"
        let caretAtEnd = "f.focus(); f.setSelectionRange(11,11)"
        let keep = "document.onkeydown = e => { if (e.altKey) { window.__kept = 1; e.preventDefault() } }"
        // "nobody" is the page keeping a key it had nothing to do with — an empty field, a page already
        // at its end. Nothing visible changes, so the evidence is the absence of an "after the page"
        // line in `SIX_UI_DEBUG`'s trace; a rail that moved would say "six".
        typealias Case = (name: String, html: String, setup: String, flags: NSEvent.ModifierFlags, code: UInt16, characters: String, expect: String)
        let cases: [Case] = [
            ("⌥← on a short page", "short", "", .option, KeyCode.leftArrow.rawValue, "\u{F702}", "six"),
            ("⌥← in a field with text", field, caretAtEnd, .option, KeyCode.leftArrow.rawValue, "\u{F702}", "page"),
            ("⌥← in an empty field", "<input id=f>", "f.focus()", .option, KeyCode.leftArrow.rawValue, "\u{F702}", "nobody"),
            ("⌥↓ on a page that scrolls", tall, "", .option, KeyCode.downArrow.rawValue, "\u{F701}", "page"),
            ("⌥↓ at the bottom of it", tall, "window.scrollTo(0, 99999)", .option, KeyCode.downArrow.rawValue, "\u{F701}", "nobody"),
            ("⌥↓ on a short page", "short", "", .option, KeyCode.downArrow.rawValue, "\u{F701}", "six"),
            ("⌥W on a short page", "short", "", .option, KeyCode.w.rawValue, "∑", "six"),
            ("⌥W in a field", "<input id=f>", "f.focus()", .option, KeyCode.w.rawValue, "∑", "page"),
            ("⌥W to a page that wants ⌥", "short", keep, .option, KeyCode.w.rawValue, "∑", "page"),
            ("⌃⌥← in a field with text", field, caretAtEnd, [.control, .option], KeyCode.leftArrow.rawValue, "\u{F702}", "six"),
            ("⌃⌥← to a page that wants ⌥", "short", keep, [.control, .option], KeyCode.leftArrow.rawValue, "\u{F702}", "six"),
        ]
        let state = """
            const f = document.getElementById('f');
            return JSON.stringify({y: scrollY, value: f ? f.value : null, caret: f ? f.selectionStart : null, kept: window.__kept || 0})
            """

        for item in cases {
            browser.selectTab(tab.id)
            if browser.layout.fill == .window { browser.toggleFullWindow() }
            try? await Task.sleep(for: .milliseconds(300))
            _ = try? await tab.page.callJavaScript("document.onkeydown = null; window.__kept = 0; window.__seen = 0; document.body.innerHTML = \"\(item.html)\"; window.scrollTo(0, 0); if (!window.__counting) { window.__counting = 1; addEventListener('keydown', () => window.__seen++, true) }")
            if !item.setup.isEmpty { _ = try? await tab.page.callJavaScript(item.setup) }
            _ = window.makeFirstResponder(web)
            try? await Task.sleep(for: .milliseconds(250))
            let before = (try? await tab.page.callJavaScript(state)) as? String ?? "?"
            let rail = (browser.selectedTabID, browser.layout.focusedWorkspaceIndex, browser.layout.fill)

            // What a keyboard sends: «∑» typed, «w» for the menu bar to match a key equivalent against.
            let ignoring = item.code == KeyCode.w.rawValue ? "w" : item.characters
            post(flags: item.flags, rawCode: item.code, characters: item.characters, ignoringModifiers: ignoring, in: window)
            try? await Task.sleep(for: .milliseconds(700))

            let after = (try? await tab.page.callJavaScript(state)) as? String ?? "?"
            let sixActed = browser.selectedTabID != rail.0 || browser.layout.focusedWorkspaceIndex != rail.1
                || browser.layout.fill != rail.2
            // A reserved key is never offered, so the page seeing it at all is the failure. What a page
            // shows afterwards cannot say that on its own: the rail moving the keyboard off it can
            // leave a caret somewhere else, and did once in two runs.
            let seen = (try? await tab.page.callJavaScript("return window.__seen")) as? Int ?? -1
            let reserved = item.flags.contains(.control)
            let pageActed = reserved ? seen != 0 : before != after
            let who = sixActed && pageActed ? "BOTH" : sixActed ? "six" : pageActed ? "page" : "nobody"
            let verdict = who == item.expect ? "ok" : "EXPECTED \(item.expect)"
            note("page first: \(item.name) → \(who) [\(verdict)] — page \(before) → \(after)")

            // Put the rail back where the case found it.
            if browser.layout.focusedWorkspaceIndex != rail.1 { browser.focusWorkspace(rail.1 - browser.layout.focusedWorkspaceIndex) }
            try? await Task.sleep(for: .milliseconds(300))
        }

        await nativeField(browser, in: window)

        browser.closeTab(tab.id)
        browser.closeTab(left.id)
    }

    /// Six's own field, which cannot hand a key back: `yieldsToCaret` decides there, and the menu bar
    /// is asked for a key equivalent before the field is — so this is also the check that no menu
    /// item still holds `⌥W` and takes the «∑» before the field can type it.
    private static func nativeField(_ browser: BrowserState, in window: NSWindow) async {
        let start = browser.newTab()
        try? await Task.sleep(for: .milliseconds(1200))
        guard let text = window.firstResponder as? NSText else {
            browser.closeTab(start.id)
            return note("page first: no native field has the caret on a new window (\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")) — not measured")
        }
        let fill = browser.layout.fill
        post(flags: .option, rawCode: KeyCode.w.rawValue, characters: "∑", ignoringModifiers: "w", in: window)
        try? await Task.sleep(for: .milliseconds(500))
        let typed = text.string
        let who = browser.layout.fill != fill ? (typed.contains("∑") ? "BOTH" : "six") : (typed.contains("∑") ? "field" : "nobody")
        note("page first: ⌥W in the start page's field → \(who) [\(who == "field" ? "ok" : "EXPECTED field")] — field \"\(typed)\"")
        if browser.layout.fill != fill { browser.toggleFullWindow() }

        let selected = browser.selectedTabID
        post(flags: .option, rawCode: KeyCode.leftArrow.rawValue, characters: "\u{F702}", in: window)
        try? await Task.sleep(for: .milliseconds(500))
        let moved = browser.selectedTabID != selected
        note("page first: ⌥← in a field with text in it → \(moved ? "six" : "field") [\(moved ? "EXPECTED field" : "ok")]")
        browser.selectTab(start.id)
        try? await Task.sleep(for: .milliseconds(300))

        // The control, last: the reserved key, from the same field, has to leave it.
        _ = window.makeFirstResponder(text)
        let before = browser.selectedTabID
        post(flags: [.control, .option], rawCode: KeyCode.leftArrow.rawValue, characters: "\u{F702}", in: window)
        try? await Task.sleep(for: .milliseconds(500))
        let left = browser.selectedTabID != before
        note("page first: ⌃⌥← from that field (the control) → \(left ? "six" : "field") [\(left ? "ok" : "EXPECTED six")]")

        await lettingGo(of: start, browser, in: window)
        browser.closeTab(start.id)
    }

    /// The start page gives the caret up: `Esc` clears the field and then leaves it, and a click beside
    /// the field leaves it too. Measured as who holds the keyboard, since that is the whole point —
    /// an `⌥` key reaches the rail only once no field does.
    private static func lettingGo(of start: BrowserTab, _ browser: BrowserState, in window: NSWindow) async {
        browser.selectTab(start.id)
        try? await Task.sleep(for: .milliseconds(400))
        guard let text = window.firstResponder as? NSText else {
            return note("page first: the start page's field did not take the caret back — Esc and click not measured")
        }
        let field = text.convert(text.bounds, to: nil)

        post(flags: [], rawCode: KeyCode.escape.rawValue, characters: "\u{1b}", in: window)
        try? await Task.sleep(for: .milliseconds(300))
        let cleared = (window.firstResponder as? NSText)?.string
        post(flags: [], rawCode: KeyCode.escape.rawValue, characters: "\u{1b}", in: window)
        try? await Task.sleep(for: .milliseconds(300))
        let left = !(window.firstResponder is NSText)
        note("page first: Esc, Esc in the start page's field → text \"\(cleared ?? "(no field)")\", then \(left ? "let go" : "still in the field")"
            + " [\(cleared == "" && left ? "ok" : "EXPECTED cleared, then let go")]")

        click(at: CGPoint(x: field.midX, y: field.midY), in: window)
        try? await Task.sleep(for: .milliseconds(400))
        let back = window.firstResponder is NSText
        // Well below the field, where an empty field has no list: the gradient.
        click(at: CGPoint(x: field.midX, y: max(8, field.minY - 220)), in: window)
        try? await Task.sleep(for: .milliseconds(400))
        let away = !(window.firstResponder is NSText)
        note("page first: click the field, then beside it → \(back ? "in" : "not in"), then \(away ? "let go" : "still in the field")"
            + " [\(back && away ? "ok" : "EXPECTED in, then let go")]")
    }

    private static func click(at point: CGPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
#endif
