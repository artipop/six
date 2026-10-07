#if os(macOS)
import AppKit
import WebKit

/// `SAVOIA_INSPECTOR_SELFTEST=1`: ⌥⌘I on a real tab — docked, under the find bar, across a navigation,
/// a tab switch and a discard, and beside another tab. Closes what it opens.
enum WebInspectorSelfTest {
    static func run(_ browser: BrowserState) async {
        func say(_ line: String) { Log.info(.devtools, "inspector selftest: \(line)") }
        func pause(_ milliseconds: Int = 900) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func page(_ text: String) -> URL { URL(string: "data:text/html,<title>\(text)</title><h1>\(text)</h1>")! }
        func size(_ view: NSView?) -> String { view.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "—" }
        func describe(_ tab: BrowserTab) -> String {
            guard let view = tab.livePage else { return "no page" }
            let frontend = WebInspector.frontend(of: view)
            return "open \(tab.isInspected), docked \(WebInspector.isDocked(on: view)), page \(size(view)) in host \(size(view.superview)), "
                + "frontend \(size(frontend)) in \(frontend?.window.map { "\(type(of: $0))" } ?? "no window"), title \(tab.title)"
        }
        func press(_ name: String, flags: NSEvent.ModifierFlags, code: UInt16, characters: String, in window: NSWindow?) async {
            guard let window else { return say("\(name): no window") }
            KeySelfTest.post(flags: flags, rawCode: code, characters: characters, in: window)
            await pause()
        }
        func optionCommandI(in window: NSWindow?) async {
            await press("⌥⌘I", flags: [.command, .option], code: 34, characters: "i", in: window)
        }

        NSApp.activate()
        await pause(1500)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeKey }) else {
            return say("no window")
        }
        window.makeKeyAndOrderFront(nil)
        say("available \(WebInspector.isAvailable), window \(size(window.contentView))")

        let tab = browser.newTab(url: page("one"))
        await pause(1500)
        if let view = tab.livePage { _ = window.makeFirstResponder(view) }
        say("before: \(describe(tab)), open to Safari \(tab.livePage?.isInspectable ?? false)")

        await optionCommandI(in: window)
        say("⌥⌘I, page focused: \(describe(tab))")

        if let view = tab.livePage, let frontend = WebInspector.frontend(of: view) {
            let script = "JSON.stringify([WI.networkManager.mainFrame.url, WI.tabBrowser.tabBar.tabBarItems.map(item => item.representedObject?.constructor.name ?? item.title)])"
            let answer = try? await frontend.evaluateJavaScript(script)
            say("the frontend's own account: \(answer as? String ?? "nothing")")
        }

        browser.find.show(tab.id)
        await pause()
        say("find bar shown: \(describe(tab))")
        browser.find.hide(tab.id)
        await pause()
        say("find bar hidden: \(describe(tab))")

        let frame = window.frame
        window.setFrame(frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1), display: true)
        await pause()
        say("window smaller: \(describe(tab))")
        window.setFrame(frame, display: true)
        await pause()
        say("window back: \(describe(tab))")

        tab.load(page("two"))
        await pause(1500)
        say("navigated: \(describe(tab))")

        let other = browser.newTab(url: page("other"))
        await pause(1500)
        say("behind another tab: \(describe(tab))")
        browser.pages.discardBackgroundPages()
        await pause(1500)
        say("background pages discarded: live \(tab.hasLivePage), \(describe(tab))")
        tab.discard()
        say("discarded by hand: live \(tab.hasLivePage)")
        browser.selectTab(tab.id)
        await pause(1500)
        say("shown again: \(describe(tab))")

        await optionCommandI(in: window)
        say("⌥⌘I again: \(describe(tab))")
        if let view = tab.livePage, let frontend = WebInspector.frontend(of: view) {
            say("frontend takes the keyboard: \(window.makeFirstResponder(frontend))")
            await optionCommandI(in: window)
            say("⌥⌘I, inspector focused: \(describe(tab))")
        }

        browser.showSideBySide(tab.id, other.id)
        browser.selectTab(tab.id)
        await pause(1500)
        say("side by side: \(describe(tab))")
        await optionCommandI(in: window)
        say("⌥⌘I beside another tab: \(describe(tab))")
        if let view = tab.livePage, let own = WebInspector.frontend(of: view)?.window, own !== window {
            let before = browser.tabs.count
            own.makeKeyAndOrderFront(nil)
            await press("⌘W", flags: .command, code: 13, characters: "w", in: own)
            say("⌘W in the inspector's window: tabs \(before) → \(browser.tabs.count), tab alive \(browser.tab(tab.id) != nil), "
                + (browser.tab(tab.id).map(describe) ?? "—"))
        }

        // The control goes last: it takes the selection with it.
        window.makeKeyAndOrderFront(nil)
        let before = browser.tabs.count
        await press("⌘T", flags: .command, code: 17, characters: "t", in: window)
        say("⌘T (the control): tabs \(before) → \(browser.tabs.count)")
        if let opened = browser.selectedTab, opened.id != tab.id, opened.id != other.id { browser.closeTab(opened.id) }
        if browser.tab(tab.id) != nil { browser.closeTab(tab.id) }
        if browser.tab(other.id) != nil { browser.closeTab(other.id) }
        say("done")
    }
}
#endif
