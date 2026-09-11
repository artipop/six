#if os(macOS)
import AppKit
#endif
import SwiftUI
import WebKit

/// The page's context menu — six's, not WebKit's.
///
/// WebKit's own menu carries "Open Link in New Window" and "Download Linked File", and in a SwiftUI
/// `WebView` **both are dead**: they go straight to the UI client and to a download delegate, the two
/// seats this API has no chair for, and never reach the navigation decider. Verified with a real
/// right-click: the items appear, selecting them produces no navigation, no request and no file.
/// There is no way to repair them in place — `webViewContextMenu` is the only hook, and it replaces
/// the whole menu rather than adding to it.
///
/// So the menu is six's. Which means it has to carry its own weight: the link commands that were
/// broken, and the page commands (moving through history, the clipboard) that were WebKit's and would
/// otherwise be gone. What is left behind with WebKit's menu is what `ActivatedElementInfo` does not
/// describe — it is a link URL and nothing else, so an image has no Save Image, and a selection has
/// no Look Up. That is the price of the two items working at all.
extension View {
    @ViewBuilder
    func pageContextMenu(for tab: BrowserTab, in browser: BrowserState, showsPageCommands: Bool = true) -> some View {
        #if os(macOS)
        webViewContextMenu { info in
            if let url = info.linkURL {
                Button("Open Link") { browser.openLink(url, in: tab) }
                Button("Open Link in New Window") { browser.openInNewWindow(url, from: tab, background: false) }
                // "Behind" rather than "in the Background": in a strip the window is not behind
                // anything, it is the next column along, and the focus simply does not go there.
                Button("Open Link Behind") { browser.openInNewWindow(url, from: tab, background: true) }
                // The one a source is read with: the page stays where it is and the link opens in
                // the other half of the same window, side by side with what sent you there. On a
                // window already sharing its column there is no room, and the link opens behind.
                Button("Open Link Beside") { browser.openBeside(url, from: tab) }
                Button("Download Linked File") {
                    browser.download(URLRequest(url: url), suggestedName: nil, from: tab)
                }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Divider()
            }
            if showsPageCommands {
                Button("Back") { tab.goBack() }
                    .disabled(!tab.canGoBack)
                Button("Forward") { tab.goForward() }
                    .disabled(!tab.canGoForward)
                Button(tab.isLoading ? "Stop" : "Reload") { tab.reloadOrStop() }
                Divider()
            }
            // Through the responder chain, so the page's own selection and its text fields answer —
            // the same route the Edit menu takes.
            Button("Cut") { send("cut:") }
            Button("Copy") { send("copy:") }
            Button("Paste") { send("paste:") }
            Button("Select All") { send("selectAll:") }
            Divider()
            // The window's own commands. They used to live on its title bar; the page runs edge to
            // edge now, so the page's menu is where the mouse can still reach them.
            Menu("This Window") { ColumnMenu(tab: tab).environment(browser) }
            // Whatever an installed extension asked to add here — `menus` in its manifest, or
            // `contextMenus.create` at runtime. Below six's own items, the way a browser's own
            // context menu items sit above an extension's contributions in every other one too.
            if let items = browser.extensions?.contextMenuItems(for: tab), !items.isEmpty {
                Divider()
                ExtensionMenuItems(items: items)
            }
        }
        #elseif os(iOS)
        // A phone has no context menu on a page: the long press is WebKit's own, and there is no
        // `webViewContextMenu` there to take it over.
        self
        #endif
    }
}

#if os(macOS)
@MainActor
private func send(_ selector: String) {
    NSApp.sendAction(Selector((selector)), to: nil, from: nil)
}

@MainActor
private func fireExtensionMenuItem(_ item: NSMenuItem) {
    guard let action = item.action else { return }
    NSApp.sendAction(action, to: item.target, from: item)
}

/// WebKit hands back real `NSMenuItem`s — target and action already wired to the extension — so
/// this only has to place them, recursing into whatever nesting the extension itself asked for
/// (`contextMenus.create(..., parentId: ...)` builds a submenu the same way a manifest's `menus`
/// entry can). A named type rather than a function returning `some View`, because a function
/// cannot call itself through an opaque return type — the compiler has nothing to resolve it to.
/// `\.self` for `ForEach`'s id: an `NSMenuItem` is an `NSObject`, and identity is exactly what
/// tells two of an extension's items apart — nothing here reads their content.
private struct ExtensionMenuItems: View {
    let items: [NSMenuItem]

    var body: some View {
        ForEach(items, id: \.self) { item in
            if item.isSeparatorItem {
                Divider()
            } else if let submenu = item.submenu {
                Menu(item.title) { ExtensionMenuItems(items: submenu.items) }
            } else {
                Button(item.title) { fireExtensionMenuItem(item) }
                    .disabled(!item.isEnabled)
            }
        }
    }
}
#endif
