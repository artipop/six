#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation

/// The addresses six does not open itself: `magnet:`, `mailto:`, `tel:`, whatever an installed app
/// has claimed. A `WebPage` asked to load one does nothing at all — no error, no page, no sign that
/// the click was even seen — so every route that can produce a URL asks this first and hands the
/// ones that are not six's to the system: the navigation decider, the address bar, and the column a
/// `target=_blank` would have opened.
enum ExternalScheme {
    /// What a window of six's can actually show: what WebKit fetches, what six draws, and the two
    /// schemes an MCP app is served on. Everything else belongs to somebody else's app.
    ///
    /// An allowlist rather than a list of the schemes to hand off, because the ones to hand off are
    /// unbounded — that is what a custom scheme *is* — while the ones a window shows are these.
    /// `webkit-extension` is in it because a hosted `WKWebExtension` navigates to its own pages.
    static let own: Set<String> = [
        "http", "https", "file", "about", "data", "blob", "javascript", "six",
        "webkit-extension", "safari-web-extension",
        MCPAppScheme.shell, MCPAppScheme.content,
    ]

    /// Is this somebody else's to open?
    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !own.contains(scheme)
    }

    /// Hands the URL to whichever app claims the scheme. False when the system has nobody for it —
    /// on macOS it puts up its own "no application can open" sheet, which is the honest answer to a
    /// magnet link on a machine with no torrent client.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }

    /// Does an app actually claim this scheme? Asked before the address bar treats typed text as an
    /// address rather than a search: `magnet:?xt=…` is an address on a machine with a torrent client
    /// and a search query on one without, and «note: buy milk» stays a search everywhere.
    static func hasHandler(for url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #else
        return false
        #endif
    }
}

#if os(macOS)

/// LaunchServices' side of the app: URLs and files handed to six from outside — a link clicked in
/// Mail, `open -a six …`, a double-clicked `.html`, a Handoff tile from an iPhone — and the switch
/// that makes six the default browser.
///
/// The URLs themselves arrive in `sixApp.body` (`.onOpenURL`, `.onContinueUserActivity`): SwiftUI
/// raises the window and hands them over. That only works because six's scene is a `Window` and not
/// a `WindowGroup` — see the comment there.
enum ExternalOpen {
    /// A `.webloc` is a plist wrapping the URL someone saved; open what it points at, not the file.
    static func resolve(_ url: URL) -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String,
              let target = URL(string: string)
        else { return url }
        return target
    }

    /// macOS hands six the link but leaves whatever app the click came from in front, so the window
    /// asks for the front itself — and a window someone minimised has to be dug out first.
    @MainActor
    static func comeForward() {
        NSApp.activate()
        guard let window = NSApp.windows.first(where: \.canBecomeMain) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ExternalOpenDelegate: NSObject, NSApplicationDelegate {
    /// The window's state is restored from six's own snapshot, not AppKit's archive; saying so
    /// silences the launch warning.
    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool { true }
}

/// Whether macOS sends the web to six, and asking it to.
enum DefaultBrowser {
    private static let probe = URL(string: "https://example.com")!
    private static let schemes = ["http", "https"]

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS puts up its own confirmation: an app cannot make itself the default silently, and
    /// shouldn't be able to.
    static func makeDefault() async {
        for scheme in schemes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            } catch {
                Log.error(.browser, "default browser (\(scheme)): \(error)")
            }
        }
    }
}
#endif
