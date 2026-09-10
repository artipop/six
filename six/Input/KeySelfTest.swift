#if os(macOS)
import AppKit
import WebKit

/// `SIX_KEY_SELFTEST=1`: what the table answers, for every chord in it, in every context there is.
///
/// The Mac this is developed on cannot press its own keys — `screencapture` is black and System
/// Events is refused, so nothing here can be driven from a terminal (see CLAUDE.md). The table
/// itself can be asked, though, and asking it is most of the question: "does `⌥→` work on a start
/// page" is `KeyBindings` plus a `KeyContext`, and both are values. What is left over — that a local
/// monitor beats a focused `WKWebView` to the key — is the one thing that was never in doubt.
///
/// It prints a matrix, not a verdict: a row per chord, a column per context, and the action each
/// pair lands on. A binding that used to go quiet somewhere shows up as a gap you can see.
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
            ("⌥←", .option, .leftArrow, ""),
            ("⌥→", .option, .rightArrow, ""),
            ("⌥⇧→", [.option, .shift], .rightArrow, ""),
            ("⌥↑", .option, .upArrow, ""),
            ("⌥↓", .option, .downArrow, ""),
            ("⌥Home", .option, .home, ""),
            ("⌥W", .option, .w, "w"),
            ("⌥O", .option, .o, "o"),
            ("⌥C", .option, .c, "c"),
            // The same three keys under a Russian layout, where `charactersIgnoringModifiers` is what
            // is printed on the key and not what it means. Reading only that is why these were dead.
            ("⌥W (ru)", .option, .w, "ц"),
            ("⌥O (ru)", .option, .o, "щ"),
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
            ("↩", [], .returnKey, "\r")
        ]
        var out = "[six] keys: what the table answers\n"
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
        if let field = context.field, binding.key.yields(to: field) { return "caret" }
        return label(binding.action)
    }

    private static func label(_ action: KeyAction) -> String {
        switch action {
        case .focusColumn(let step): return step < 0 ? "focus ←" : "focus →"
        case .moveColumn(let step): return step < 0 ? "move ←" : "move →"
        case .focusColumnEdge(let last): return last ? "last" : "first"
        case .focusWorkspace(let step): return step < 0 ? "ws ↑" : "ws ↓"
        case .moveColumnToWorkspace(let step): return step < 0 ? "→ws ↑" : "→ws ↓"
        case .toggleFullWidth: return "full width"
        case .toggleSplit: return "split"
        case .toggleOverview: return "overview"
        case .toggleCenterFocus: return "centre"
        case .translateSelection: return "translate"
        case .highlightSelection: return "highlight"
        case .pictureInPicture: return "picture"
        case .copyAddress: return "copy address"
        case .stepSwitcher(let step): return step < 0 ? "ring ←" : "ring →"
        case .landSwitcher: return "land"
        case .cancelSwitcher: return "cancel"
        case .leaveOverview: return "leave overview"
        }
    }

    /// The other half, and the half a matrix cannot answer: does a key posted into six's own event
    /// queue actually reach the router and move the rail?
    ///
    /// `NSApp.postEvent` needs no Accessibility — it is the app's own queue, and a local monitor is
    /// exactly what pulls events out of it — so this is as close to a finger on the key as this Mac
    /// can get. It opens three windows, walks them with `⌥→` / `⌥←`, steps a workspace with `⌥↓`,
    /// and says after each press which window the rail is on.
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
        // Enough windows to have somewhere to walk to, and not one more: this runs against the dev
        // profile's real rail, and a test that left two windows behind on every launch would be a
        // test that grows a rail.
        let strip = browser.layout.strip(for: browser.selectedProfileID)
        let here = strip.workspaces.indices.contains(browser.layout.focusedWorkspaceIndex)
            ? strip.workspaces[browser.layout.focusedWorkspaceIndex].columns.count : 0
        for _ in 0..<max(0, 3 - here) { _ = browser.newTab() }
        try? await Task.sleep(for: .milliseconds(400))
        note("rail: \(rail(browser))")
        for (name, flags, code) in [
            ("⌥→", NSEvent.ModifierFlags.option, KeyCode.rightArrow),
            ("⌥→", .option, .rightArrow),
            ("⌥←", .option, .leftArrow),
            ("⌥↓", .option, .downArrow),
            ("⌥↑", .option, .upArrow),
            ("⌥W", .option, .w),
            ("⌥W (back)", .option, .w),
            ("⌥O", .option, .o),
            ("⌥O", .option, .o)
        ] {
            post(flags: flags, code: code, in: window)
            try? await Task.sleep(for: .milliseconds(350))
            note("\(name) → \(rail(browser))")
        }

        // The ends of the rail, where a step has nowhere to go and the edge lights instead
        // (`NiriLayout.hitWall`). The empty workspace at the bottom is the sharpest case and the one
        // that was reported: a rail with nothing on it is a wall on *both* sides, so ⌥← and ⌥→ in
        // turn light one edge and then the other, and the light must not travel between them.
        for (name, flags, code) in [
            ("⌥↓ (to the empty one)", NSEvent.ModifierFlags.option, KeyCode.downArrow),
            ("⌥←", .option, .leftArrow),
            ("⌥→", .option, .rightArrow),
            ("⌥←", .option, .leftArrow),
            ("⌥↑ (back)", .option, .upArrow)
        ] {
            post(flags: flags, code: code, in: window)
            // Read while the flash is still lit. `wallGlow` is set to 1 and then to 0 by a task a
            // beat later — SwiftUI interpolates what is *drawn*, so the stored number is back to
            // zero long before a step has finished settling, and a reading taken then says nothing.
            try? await Task.sleep(for: .milliseconds(80))
            note("\(name) → \(rail(browser))")
            try? await Task.sleep(for: .milliseconds(300))
        }

        // ⌥S, and then the rail walked *through* the pair it makes. A split is the one thing that can
        // make ⌥→ land twice in the same column, so the interesting lines are the two in the middle:
        // "window 2/2, half 1/2" and then "half 2/2" without the window number moving. The last press
        // puts them back on the rail, so this leaves it as it found it — and if it ever does not, the
        // window count on the line after says so.
        // The page is made first responder by hand once, because a click is the only other way to
        // do it and this machine cannot click (CLAUDE.md). Everything after it is the question: does
        // the keyboard follow the rail's focus, or stay on the page it was given to? The `keys …`
        // half of each line answers, and its **width** says which pane holds them — half a column or
        // a whole one.
        if let page = webView(in: window) { _ = window.makeFirstResponder(page) }
        // From a known state: this runs against the dev profile's real rail, and on a rail that
        // already has a split under the focus the first ⌥S un-splits instead — which reads as the
        // key doing the opposite of what it says and cost a round of believing it.
        if browser.layout.isSplit {
            note("the focused column was already split; putting it back first")
            browser.toggleSplit()
            try? await Task.sleep(for: .milliseconds(350))
        }
        for (name, flags, code) in [
            ("⌥S (split)", NSEvent.ModifierFlags.option, KeyCode.s),
            ("⌥←", .option, .leftArrow),
            ("⌥→", .option, .rightArrow)
        ] {
            post(flags: flags, code: code, in: window)
            try? await Task.sleep(for: .milliseconds(350))
            note("\(name) → \(rail(browser))")
        }

        post(flags: .option, code: .s, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("⌥S (back) → \(rail(browser))")

        await splitKeyboard(browser, in: window)

        // A window crossing workspaces and coming back, with the ring asked about while it stands
        // over there on its own. The pair is here because it crashed six for as long as it existed
        // — two `WebView`s over one `WebPage`, the leaving row's removal transition against the
        // arriving row's build — and a key that takes the browser down is what a key test is for.
        // It leaves the rail as it found it.
        post(flags: [.option, .shift], code: .downArrow, in: window)
        try? await Task.sleep(for: .milliseconds(500))
        note("⌥⇧↓ → \(rail(browser))")
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("⌃⇥ on a rail of one → ring \(browser.switcher.ring.count)")
        browser.cancelWindowSwitch()
        post(flags: [.option, .shift], code: .upArrow, in: window)
        try? await Task.sleep(for: .milliseconds(500))
        note("⌥⇧↑ → \(rail(browser))")

        // ⌃⇥ holds a ring of the windows on *this* rail, and showing that it is this rail and not
        // the whole strip needs a window standing somewhere else. It is opened and closed here
        // rather than carried there with ⌥⇧↓ because setup is not what this is testing — that key
        // has a line of its own above.
        //
        // The ring is opened by the key alone — nothing posts a `flagsChanged`, so ⌃ never comes up
        // and the ring stays open long enough to be read.
        let elsewhere = browser.newTab(url: nil, in: browser.selectedProfileID,
                                       workspace: browser.layout.focusedWorkspaceIndex + 1,
                                       activate: false)
        try? await Task.sleep(for: .milliseconds(300))
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        let now = browser.layout.strip(for: browser.selectedProfileID)
        let onThisRail = now.workspaces.indices.contains(browser.layout.focusedWorkspaceIndex)
            ? now.workspaces[browser.layout.focusedWorkspaceIndex].columns.count : 0
        let everywhere = now.workspaces.reduce(0) { $0 + $1.columns.count }
        note("⌃⇥ → ring \(browser.switcher.ring.count), rail \(onThisRail), strip \(everywhere)")
        browser.cancelWindowSwitch()
        browser.closeTab(elsewhere.id) // the rail is left exactly as it was found

        await menuKeys(browser, in: window)
    }

    /// The `⌘` keys, which are menu items rather than table rows — here for the same doubt the
    /// table was written to settle, pointing the other way.
    ///
    /// A key equivalent is offered to the key window first and to the main menu second, so a focused
    /// `WKWebView` stands in front of every menu item six has; WebKit keeps `⌥←` exactly that way.
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
            _ = try? await tab.page.callJavaScript("window.__six = 1")
            post(flags: .command, rawCode: 15, characters: "r", in: window)
            try? await Task.sleep(for: .milliseconds(700))
            let mark = try? await tab.page.callJavaScript("return window.__six")
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
        browser.closeTab(tab.id) // as with the rail, nothing is left behind
    }

    private static func describe(_ tab: BrowserTab) -> String {
        "\(tab.currentURL?.absoluteString ?? "—"), back \(tab.canGoBack), forward \(tab.canGoForward)"
    }

    /// Who has the keyboard, and — when it is a view — how wide it is. The width is what tells one
    /// half of a split from the other and from a whole column: the rail's focus and AppKit's first
    /// responder are two different things (`WebViewResponder`), and this is the line that says so.
    private static func keyboard(_ window: NSWindow?) -> String {
        guard let window else { return "no key window" }
        guard let responder = window.firstResponder else { return "none" }
        let name = String(describing: type(of: responder))
        guard let view = responder as? NSView else { return name }
        // The width alone cannot tell one half of a split from the other — they are the same width —
        // so the window that owns the view is named, and whether that is the window the rail has the
        // focus on. "disagrees" is the bug this line was added for.
        let owner = WebViewResponder.shared.owner(of: responder)
        let owned = owner.map { String($0.uuidString.prefix(8)) } ?? "unknown"
        return "\(name) \(Int(view.bounds.width))pt \(owned)"
    }

    /// Whether the keyboard is where the rail's focus is. Silent when no page holds the keyboard at
    /// all — a text field having it is not a disagreement, it is `⌘L`.
    private static func agreement(_ focused: UUID?, _ window: NSWindow?) -> String {
        guard let owner = WebViewResponder.shared.owner(of: window?.firstResponder) else { return "" }
        return owner == focused ? " (agrees)" : " (DISAGREES)"
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

    /// **Does the keyboard follow the rail's focus?** The question a split made worth asking, and
    /// the one that needs a setup of its own.
    ///
    /// Two windows with **real pages**, because this is a question about `WKWebView`s and the
    /// windows the rest of this test uses have none: six's start page is SwiftUI, so a split of two
    /// of them has nothing for a first responder to be, and the first version of this measured
    /// exactly that and reported the window itself holding the keys. And the field is let go of by
    /// hand, because a launched window hands the keyboard to the address field and
    /// `WebViewResponder` deliberately never takes it off a text field.
    ///
    /// `(agrees)` is the whole answer, and it has to survive a step: ⌥→ moves the rail's focus to
    /// the other half, and the keyboard has to arrive there too. `(DISAGREES)` is the bug this was
    /// written for — one half highlighted while what you type lands in the other. The two windows
    /// are closed at the end, so the rail is left as it was found.
    private static func splitKeyboard(_ browser: BrowserState, in window: NSWindow) async {
        guard let blank = URL(string: "about:blank") else { return }
        let left = browser.newTab(url: blank)
        let right = browser.newTab(url: blank)
        try? await Task.sleep(for: .seconds(1))
        browser.selectTab(left.id)
        try? await Task.sleep(for: .milliseconds(300))

        post(flags: .option, code: .s, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("two pages, ⌥S → \(rail(browser))")

        window.makeFirstResponder(nil)
        WebViewResponder.shared.focus(browser.selectedTabID)
        try? await Task.sleep(for: .milliseconds(150))
        note("keyboard handed to the focused half → \(rail(browser))")

        post(flags: .option, code: .rightArrow, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("⌥→ (the other half) → \(rail(browser))")
        post(flags: .option, code: .leftArrow, in: window)
        try? await Task.sleep(for: .milliseconds(400))
        note("⌥← (back again) → \(rail(browser))")

        // **⌃Tab, twice over.** The ring stops at the column everywhere except the column you are
        // standing in, so two answers have to come out of the same key.
        //
        // Here, having just walked between the halves with the arrows, one ⌃⇥ has to land on the
        // other half — the complaint this was written for was that it threw you at the column next
        // door instead. `ring` counts the windows of this column separately and the rest by column,
        // so it comes out one *more* than the number of columns.
        let windows = browser.layout.focusedWorkspace?.columns.flatMap(\.tabIDs).count ?? 0
        let columns = browser.layout.focusedWorkspace?.columns.count ?? 0
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        let landing = browser.switcher.selection
        note("⌃⇥ inside a split → ring \(browser.switcher.ring.count), columns \(columns), windows \(windows),"
            + " lands on \(landing == right.id ? "the other half" : landing == left.id ? "itself" : "another column")")
        // What the panel is actually showing, card by card. A ring that reads correctly by the
        // numbers can still put the same picture on the screen twice — which is how the halves of
        // the focused column arrived, each card drawing the whole pair — and a count cannot say so.
        note("the cards: " + ringCards(browser))
        browser.cancelWindowSwitch()
        try? await Task.sleep(for: .milliseconds(200))

        // The same ring, from the other half. The pair has to be drawn in the same order both times:
        // on the rail those two are always left then right, and a row that swapped them from one
        // press to the next asked you to read the pair again every time. Only the `*` should move.
        post(flags: .option, code: .rightArrow, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        note("the cards, from the other half: " + ringCards(browser))
        browser.cancelWindowSwitch()
        try? await Task.sleep(for: .milliseconds(250))

        // And from a window that is *not* in the pair, the same key has to go back to where it came
        // from — the column, with the half it was last in — rather than into the split's other half.
        post(flags: .option, code: .leftArrow, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        post(flags: .control, code: .tab, in: window)
        try? await Task.sleep(for: .milliseconds(350))
        let back = browser.switcher.selection
        note("⌃⇥ from the window before it → lands on \(back == left.id ? "the half it came from" : "something else"),"
            + " ring \(browser.switcher.ring.count)")
        browser.cancelWindowSwitch()
        try? await Task.sleep(for: .milliseconds(200))

        browser.closeTab(right.id, remembering: false)
        browser.closeTab(left.id, remembering: false)
        try? await Task.sleep(for: .milliseconds(300))
        note("the two pages closed → \(rail(browser))")
    }

    /// Every card in the ring as it is drawn: what it stands for, how wide it is, and what is in it.
    /// The one thing a card count cannot tell you is whether two of them look the same.
    private static func ringCards(_ browser: BrowserState) -> String {
        browser.switcher.ring.enumerated().map { position, id in
            // The id and not only the title: two windows on one rail can be the same page, and a
            // line of identical titles cannot say whether an order was kept or swapped — which is
            // the question this was printed for.
            let inside = browser.ringWindows(at: id).map { window -> String in
                let name = browser.tab(window)?.title.prefix(10) ?? "?"
                return "\(window.uuidString.prefix(4)) \(name)"
            }
            let width = browser.ringCardIsHalfWide(id) ? "half" : "whole"
            let chosen = position == browser.switcher.index ? "*" : ""
            return "\(chosen)[\(width): \(inside.joined(separator: " | "))]"
        }.joined(separator: " ")
    }

    /// Which window on the rail is focused, and how the rail is showing it.
    private static func rail(_ browser: BrowserState) -> String {
        let layout = browser.layout
        let strip = layout.strip(for: browser.selectedProfileID)
        let workspace = strip.workspaces.indices.contains(layout.focusedWorkspaceIndex)
            ? strip.workspaces[layout.focusedWorkspaceIndex] : nil
        let column = workspace.flatMap { $0.focusedColumn?.focusedTabID }
        let position = workspace.flatMap { space in column.flatMap { id in space.columns.firstIndex { $0.holds(id) } } }
        // Which half of a split is focused, when the window is sharing its column. A rail walked with
        // ⌥→ reads identically with and without a split until this says otherwise: both are "window
        // 2 of 3", and only one of them is standing in half a column.
        let half = workspace.flatMap { space -> String? in
            guard let index = position, space.columns.indices.contains(index), space.columns[index].isSplit
            else { return nil }
            return ", half \(space.columns[index].pane + 1)/2"
        }
        // The wall belongs here for the same reason the focus does: it is what the rail answered
        // with, and on an end of the rail it is the *only* thing it answered with.
        let wall = layout.wallGlow > 0.005 ? layout.wall.map { ", wall \($0) \(String(format: "%.2f", layout.wallGlow))" } : nil
        return "workspace \(layout.focusedWorkspaceIndex + 1)/\(strip.workspaces.count),"
            + " window \(position.map { $0 + 1 } ?? 0)/\(workspace?.columns.count ?? 0)"
            + (half ?? "")
            + ", keys \(keyboard(NSApp.keyWindow ?? NSApp.mainWindow))"
            + agreement(column, NSApp.keyWindow ?? NSApp.mainWindow)
            + ", fill \(layout.fill)\(layout.isOverview ? ", overview" : "")"
            + (wall ?? "")
    }

    private static func post(flags: NSEvent.ModifierFlags, code: KeyCode, in window: NSWindow) {
        post(flags: flags, rawCode: code.rawValue, characters: characters(for: code), in: window)
    }

    /// The menu's keys are not the table's keys, and `KeyCode` is the table's — a `case r` there
    /// would be a name nothing in `KeyBindings` ever says. They are posted by number instead.
    private static func post(flags: NSEvent.ModifierFlags, rawCode: UInt16, characters: String, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
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
        case .o: return "o"
        case .s: return "s"
        case .p: return "p"
        case .t: return "t"
        case .w: return "w"
        }
        return String(UnicodeScalar(UInt32(scalar)) ?? " ")
    }

    private static func note(_ message: String) {
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
