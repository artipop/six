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
    static func run(_ browser: BrowserState) async {
        func say(_ line: String) { Log.info(.ui, "tabs selftest: \(line)") }
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

        browser.closeTab(probe.id, remembering: false)
        for id in folded { browser.layout.setCollapsed(true, workspace: id) }
        browser.setInterfaceStyle(started)
        try? await Task.sleep(for: .milliseconds(300))
        say("cleaned up: \(groups()), back on \(browser.interfaceStyle.rawValue) — survived")
    }
}
#endif
