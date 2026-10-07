#if os(macOS)
import AppKit

/// The page's context menu — Savoia's, built for the link under the pointer (`PageDelegate`).
enum PageContextMenu {
    static func menu(for tab: BrowserTab, link: URL?, in browser: BrowserState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ActionItem(title: title, run: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if let url = link {
            add(String(localized: "Open Link")) { browser.openLink(url, in: tab) }
            add(String(localized: "Open Link in New Tab")) { browser.openInNewWindow(url, from: tab, background: false) }
            add(String(localized: "Open Link Behind")) { browser.openInNewWindow(url, from: tab, background: true) }
            // Beside the page it was followed from; behind, when that page already shares its column.
            add(String(localized: "Open Link Beside")) { browser.openBeside(url, from: tab) }
            add(String(localized: "Download Linked File")) {
                browser.download(URLRequest(url: url), suggestedName: nil, from: tab)
            }
            add(String(localized: "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            menu.addItem(share([url], titled: String(localized: "Share Link")))
            menu.addItem(.separator())
        }
        if !tab.isDocument {
            add(String(localized: "Back"), enabled: tab.canGoBack) { tab.goBack() }
            add(String(localized: "Forward"), enabled: tab.canGoForward) { tab.goForward() }
            add(tab.isLoading ? String(localized: "Stop") : String(localized: "Reload")) { tab.reloadOrStop() }
            add(String(localized: "Save As…"), enabled: !tab.showsStartPage) {
                Task { await Exporter.saveAs(tab, listingIn: browser.downloads) }
            }
            if let url = tab.shareableURL { menu.addItem(share([url], titled: String(localized: "Share"))) }
            menu.addItem(.separator())
        }
        // Through the responder chain, as the Edit menu does.
        add(String(localized: "Cut")) { send("cut:") }
        add(String(localized: "Copy")) { send("copy:") }
        add(String(localized: "Paste")) { send("paste:") }
        add(String(localized: "Select All")) { send("selectAll:") }
        menu.addItem(.separator())
        add(String(localized: "Picture in Picture")) { tab.togglePictureInPicture() }
        if browser.profiles.count > 1 {
            let profiles = NSMenu()
            for profile in browser.profiles where profile.id != tab.profileID {
                let item = ActionItem(title: profile.name) { browser.moveTab(tab.id, toProfile: profile.id) }
                item.isEnabled = browser.canMove(tab, to: profile)
                profiles.addItem(item)
            }
            profiles.autoenablesItems = false
            let item = NSMenuItem(title: String(localized: "Move to Profile"), action: nil, keyEquivalent: "")
            item.submenu = profiles
            menu.addItem(item)
        }
        add(String(localized: "Close Tab")) { browser.closeTab(tab.id) }
        if let items = browser.extensions?.contextMenuItems(for: tab), !items.isEmpty {
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }
        return menu
    }

    private static func share(_ items: [Any], titled title: String) -> NSMenuItem {
        let item = NSSharingServicePicker(items: items).standardShareMenuItem
        item.title = title
        return item
    }

    private static func send(_ selector: String) {
        NSApp.sendAction(Selector((selector)), to: nil, from: nil)
    }
}

private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { run() }
}
#endif
