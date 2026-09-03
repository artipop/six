#if os(macOS)
import AppKit

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
        case .toggleOverview: return "overview"
        case .toggleCenterFocus: return "centre"
        case .translateSelection: return "translate"
        case .highlightSelection: return "highlight"
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
    }

    /// Which window on the rail is focused, and how the rail is showing it.
    private static func rail(_ browser: BrowserState) -> String {
        let layout = browser.layout
        let strip = layout.strip(for: browser.selectedProfileID)
        let workspace = strip.workspaces.indices.contains(layout.focusedWorkspaceIndex)
            ? strip.workspaces[layout.focusedWorkspaceIndex] : nil
        let column = workspace.flatMap { $0.focusedColumn?.tabID }
        let position = workspace.flatMap { space in column.flatMap { id in space.columns.firstIndex { $0.tabID == id } } }
        // The wall belongs here for the same reason the focus does: it is what the rail answered
        // with, and on an end of the rail it is the *only* thing it answered with.
        let wall = layout.wallGlow > 0.005 ? layout.wall.map { ", wall \($0) \(String(format: "%.2f", layout.wallGlow))" } : nil
        return "workspace \(layout.focusedWorkspaceIndex + 1)/\(strip.workspaces.count),"
            + " window \(position.map { $0 + 1 } ?? 0)/\(workspace?.columns.count ?? 0)"
            + ", fill \(layout.fill)\(layout.isOverview ? ", overview" : "")"
            + (wall ?? "")
    }

    private static func post(flags: NSEvent.ModifierFlags, code: KeyCode, in window: NSWindow) {
        let characters = Self.characters(for: code)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code.rawValue) else { return }
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
        case .t: return "t"
        case .w: return "w"
        }
        return String(UnicodeScalar(UInt32(scalar)) ?? " ")
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("[six] keys: \(message)\n".utf8))
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
