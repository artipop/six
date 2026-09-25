#if os(macOS)
import SwiftUI

/// `SIX_TABS_SELFTEST=1` — the tab bar' verbs run against the real browser, and the two faces
/// swapped back and forth with live pages on screen, saying what each step left behind.
///
/// The swap is the part worth a harness: both faces build a `WebView` over the page in front, and
/// WebKit allows one. A swap that ever built the second before the first let go traps in
/// `makeViewProvider` and takes the browser with it — so the run ends with "survived", or not at all.
/// It works on the dev profile's real strip and cleans up the one tab and group it makes.
enum TabsSelfTest {
    /// Every menu item that answers ⌘W, with what it would do — the key once closed the whole window
    /// with the tabs up, and quit six with it.
    static func menuForCommandW(_ say: (String) -> Void) {
        // SwiftUI fills its menus in when they are about to be shown; ask for that first, or this
        // reads whatever they held the last time.
        func refresh(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items { if let sub = item.submenu { refresh(sub) } }
        }
        if let main = NSApp.mainMenu { refresh(main) }
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub, path + "/" + item.title) }
                guard item.keyEquivalent.lowercased() == "w" else { continue }
                say("\(path)/\(item.title) — ⌘\(item.keyEquivalentModifierMask.rawValue) action \(item.action.map(NSStringFromSelector) ?? "nil") enabled \(item.isEnabled) hidden \(item.isHidden)")
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
        if let file = NSApp.mainMenu?.items.dropFirst().first?.submenu {
            say("  whole File: " + file.items.map { $0.isSeparatorItem ? "—" : "\($0.title)[\($0.keyEquivalent)]" }.joined(separator: " · "))
        }
    }

    /// Whether the View menu carries the tab bar's items — it follows the face, not the focus.
    static func menuForTabs(_ say: (String) -> Void) {
        let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        let next = items.contains { $0.keyEquivalent == "]" && $0.keyEquivalentModifierMask.contains(.shift) }
        let first = items.contains { $0.keyEquivalent == "1" }
        say("  tab items: ⌘⇧] \(next), ⌘1 \(first)")
    }

    static func run(_ browser: BrowserState) async {
        func say(_ line: String) { Log.info(.ui, "tabs selftest: \(line)") }
        browser.setInterfaceStyle(.row)
        try? await Task.sleep(for: .milliseconds(600))
        say("menu on the row:"); menuForCommandW(say); menuForTabs(say)
        browser.setInterfaceStyle(.tabs)
        try? await Task.sleep(for: .milliseconds(600))
        say("menu with the tabs up:"); menuForCommandW(say); menuForTabs(say)
        if ProcessInfo.processInfo.environment["SIX_CMDW_PROBE"] != nil {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
                let stack = Thread.callStackSymbols.prefix(40).joined(separator: "\n")
                Log.info(.ui, "tabs selftest: window closing \(String(describing: note.object))\n\(stack)")
            }
            let probe = browser.newTab(url: URL(string: "https://example.com/?cmdw"))
            try? await Task.sleep(for: .seconds(2))
            let before = browser.tabs.count
            NSApp.activate()
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeKey }
            window?.makeKeyAndOrderFront(nil)
            if ProcessInfo.processInfo.environment["SIX_CMDW_PROBE"] == "field", let window {
                func field(in view: NSView) -> NSTextField? {
                    if let text = view as? NSTextField, text.isEditable { return text }
                    for sub in view.subviews { if let found = field(in: sub) { return found } }
                    return nil
                }
                if let text = window.contentView.flatMap(field(in:)) {
                    say("focusing \(type(of: text)) \(text.placeholderString ?? "") — \(window.makeFirstResponder(text))")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.keyEquivalent == "t" } == true })?.submenu {
                for item in file.items where !item.isSeparatorItem {
                    say("  File: \(item.title) ⌘\(item.keyEquivalent) \(item.keyEquivalentModifierMask.rawValue) \(item.action.map(NSStringFromSelector) ?? "-") hidden \(item.isHidden)")
                }
            }
            say("posting ⌘W into \(String(describing: window)), tabs \(before), front is probe \(browser.selectedTabID == probe.id)")
            // What the W key reports depends on the layout: «ц» on the Russian one.
            let letter = ProcessInfo.processInfo.environment["SIX_CMDW_LETTER"] ?? "w"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: letter,
                                                charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 13) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            say("after ⌘W: tabs \(browser.tabs.count), windows \(NSApp.windows.filter(\.isVisible).count)")
            for tab in browser.tabs where tab.currentURL?.query?.hasPrefix("tabs-selftest") == true || tab.currentURL?.query == "cmdw" {
                browser.closeTab(tab.id, remembering: false)
            }
            return
        }
        func groups() -> String {
            TabGroup.all(in: browser).map { "\($0.title)\($0.isCollapsed ? "▸" : "")×\($0.tabIDs.count)" }
                .joined(separator: " ")
        }
        let started = browser.interfaceStyle
        // Put back at the end: dropping a tab into a group opens it, and these are the dev profile's
        // own groups, folded by a person.
        let folded = browser.layout.workspaces.filter(\.isCollapsed).map(\.id)
        let probe = browser.newTab(url: URL(string: "https://example.com/?tabs-selftest"))
        try? await Task.sleep(for: .seconds(2))

        for round in 1...3 {
            browser.setInterfaceStyle(.tabs)
            try? await Task.sleep(for: .milliseconds(700))
            say("round \(round) tabs: selected \(browser.selectedTab?.title ?? "nil"), live \(probe.hasLivePage)")
            browser.setInterfaceStyle(.row)
            try? await Task.sleep(for: .milliseconds(700))
            say("round \(round) row: selected \(browser.selectedTab?.title ?? "nil"), live \(probe.hasLivePage)")
        }
        // Faster than a frame of nothing takes: the second call lands while the first swap is still
        // waiting, and must win.
        browser.setInterfaceStyle(.tabs)
        browser.setInterfaceStyle(.row)
        browser.setInterfaceStyle(.tabs)
        try? await Task.sleep(for: .milliseconds(700))
        say("rapid swap ended on \(browser.interfaceStyle.rawValue), selected \(browser.selectedTab?.title ?? "nil")")

        say("groups: \(groups())")
        guard let group = browser.moveTabToNewGroup(probe.id) else { return say("no new group") }
        browser.layout.rename(workspaceAt: browser.layout.workspaces.firstIndex { $0.id == group } ?? 0, to: "selftest")
        say("new group: \(groups()), selected is probe \(browser.selectedTabID == probe.id)")

        // The ring on the row: ⌃Tab reaches every workspace, ⌃⇧Tab the row on screen.
        browser.setInterfaceStyle(.row)
        try? await Task.sleep(for: .milliseconds(300))
        func rows(_ ids: [UUID]) -> Int {
            Set(ids.compactMap { id in browser.layout.workspaces.firstIndex { $0.columns.contains { $0.holds(id) } } }).count
        }
        browser.stepWindowSwitch(1)
        say("row ⌃Tab ring: \(browser.switcher.ring.count) cards from \(rows(browser.switcher.ring)) workspaces")
        browser.cancelWindowSwitch()
        browser.stepWindowSwitch(-1)
        say("row ⌃⇧Tab ring: \(browser.switcher.ring.count) cards from \(rows(browser.switcher.ring)) workspaces")
        browser.cancelWindowSwitch()
        browser.setInterfaceStyle(.tabs)
        try? await Task.sleep(for: .milliseconds(300))

        browser.toggleGroup(group)
        say("fold the group in front: \(groups()), selected is probe \(browser.selectedTabID == probe.id)")
        browser.selectAdjacentTab(1)
        say("⌘⇧]: selected \(browser.selectedTab?.title ?? "nil")")
        // The ring, over every tab: it must hold tabs from more than one group, the folded one too.
        let before = browser.selectedTabID
        browser.stepWindowSwitch(1)
        let ring = browser.switcher.ring
        let groupsInRing = Set(ring.compactMap { id in browser.layout.workspaces.firstIndex { $0.columns.contains { $0.holds(id) } } })
        say("⌃Tab ring: \(ring.count) cards of \(browser.tabOrder().count) tabs, from \(groupsInRing.count) groups, holds the folded probe \(ring.contains(probe.id))")
        browser.endWindowSwitch()
        say("⌃ up: moved \(browser.selectedTabID != before), selected \(browser.selectedTab?.title ?? "nil")")
        // ⌃⇧Tab: the group in front and nothing else.
        browser.stepWindowSwitch(-1)
        let here = browser.layout.focusedWorkspace.map { Set($0.columns.flatMap(\.tabIDs)) } ?? []
        say("⌃⇧Tab ring: \(browser.switcher.ring.count) cards, all from the group in front \(browser.switcher.ring.allSatisfy(here.contains))")
        browser.cancelWindowSwitch()
        browser.toggleGroup(group)
        say("open it again: \(groups())")

        // Nameless again before it empties, or the row would stay behind asking whether to keep it.
        browser.layout.rename(workspaceAt: browser.layout.workspaces.firstIndex { $0.id == group } ?? 0, to: "")
        let order = browser.tabOrder()
        if order.count > 1, let first = TabGroup.all(in: browser).first {
            browser.placeTab(probe.id, inGroup: first.id, at: 0)
            say("dropped at the front of \(first.title): first tab is probe \(browser.tabOrder().first == probe.id)")
        }
        browser.selectTab(atPosition: 9)
        say("⌘9: selected is the last \(browser.selectedTabID == browser.tabOrder(skippingCollapsed: true).last)")

        // Picking: three tabs of its own, side by side — ⇧ takes the run, ⌘ takes one out and puts
        // it back, and the three go to a group of their own together.
        let picks = (1...3).map { browser.newTab(url: URL(string: "https://example.com/?pick\($0)")) }
        browser.clickTab(picks[0].id)
        browser.clickTab(picks[2].id, extending: true)
        say("⇧-click: picked \(browser.pickedTabsInOrder == picks.map(\.id)), front is the last \(browser.selectedTabID == picks[2].id)")
        browser.clickTab(picks[1].id, adding: true)
        say("⌘-click the middle one: picked \(browser.pickedTabsInOrder.count)")
        browser.clickTab(picks[1].id, adding: true)
        say("⌘-click it again: picked \(browser.pickedTabsInOrder.count)")
        if let made = browser.moveTabsToNewGroup(browser.pickedTabsInOrder) {
            let row = browser.layout.workspaces.first { $0.id == made }?.columns.flatMap(\.tabIDs) ?? []
            say("Add 3 Tabs to New Group: the group holds them in order \(row == picks.map(\.id))")
        }
        browser.clickTab(picks[0].id)
        say("plain click: picked \(browser.pickedTabsInOrder.count)")
        browser.closeTabs(picks.map(\.id))

        browser.closeTab(probe.id, remembering: false)
        for id in folded { browser.layout.setCollapsed(true, workspace: id) }
        browser.setInterfaceStyle(started)
        try? await Task.sleep(for: .milliseconds(300))
        say("cleaned up: \(groups()), back on \(browser.interfaceStyle.rawValue) — survived")
    }
}
#endif
