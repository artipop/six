#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation
import WebKit

/// A column, as an extension sees it. Deliberately kept off `BrowserTab` itself: the browser's model
/// should not learn the extension protocol, and WebKit identifies a tab by object identity, so the
/// store hands out one adapter per window and keeps it (`ExtensionStore.adapter(for:)`).
///
/// **`webView(for:)` is deliberately not implemented.** It wants the live `WKWebView` behind a page
/// and `WebPage` does not hand its own out; the only route to it is private layout, which six does
/// not build on. What that costs is measured in [docs/extensions.md](../../docs/extensions.md).
///
/// Everything here reads the window rather than its page — `tab.currentURL`, `tab.title` — because
/// asking `BrowserTab` for its page builds one, and an extension listing tabs must not wake a
/// hundred discarded windows.
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tab: BrowserTab
    weak var store: ExtensionStore?

    init(tab: BrowserTab, store: ExtensionStore) {
        self.tab = tab
        self.store = store
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        store?.window(for: tab.profileID)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        store?.tabs(in: tab.profileID).firstIndex { $0 === self } ?? 0
    }

    func url(for context: WKWebExtensionContext) -> URL? { tab.currentURL }
    func title(for context: WKWebExtensionContext) -> String? { tab.title }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !tab.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.browser?.selectedTabID == tab.id }
    func size(for context: WKWebExtensionContext) -> CGSize { tab.displaySize }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        tab.load(url)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        _ = tab.page.reload()
    }

    func goBack(for context: WKWebExtensionContext) async throws { tab.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { tab.goForward() }

    func activate(for context: WKWebExtensionContext) async throws {
        store?.browser?.selectTab(tab.id)
    }

    func close(for context: WKWebExtensionContext) async throws {
        store?.browser?.closeTab(tab.id)
    }
}

/// A profile's strip, as one window. Workspaces are not separate windows here — an extension moving a
/// tab between windows would mean moving a column between workspaces, which is a thing to decide when
/// something actually asks for it, not before.
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var store: ExtensionStore?
    let profileID: Profile.ID

    init(store: ExtensionStore, profileID: Profile.ID) {
        self.store = store
        self.profileID = profileID
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        store?.tabs(in: profileID) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        store?.activeTab(in: profileID)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        store?.browser?.isPrivate(profileID) ?? false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        #if os(macOS)
        NSApp.mainWindow?.frame ?? screenFrame(for: context)
        #elseif os(iOS)
        screenFrame(for: context) // the phone's window is the screen
        #endif
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        #if os(macOS)
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        #elseif os(iOS)
        UIScreen.main.bounds
        #endif
    }

    func focus(for context: WKWebExtensionContext) async throws {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
}
