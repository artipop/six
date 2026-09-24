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

        browser.toggleGroup(group)
        say("fold the group in front: \(groups()), selected is probe \(browser.selectedTabID == probe.id)")
        browser.selectAdjacentTab(1)
        say("⌃Tab: selected \(browser.selectedTab?.title ?? "nil")")
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
        browser.setInterfaceStyle(started)
        try? await Task.sleep(for: .milliseconds(300))
        say("cleaned up: \(groups()), back on \(browser.interfaceStyle.rawValue) — survived")
    }
}
#endif
