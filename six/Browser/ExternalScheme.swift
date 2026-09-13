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
///
/// In `SixCore` because the list is the same question on every front — the Windows one asks it of
/// every navigation too — and two copies of an allowlist are two chances for one of them to let a
/// scheme through. Opening is the platform's: this file does it on Apple, and a front elsewhere
/// does it with its own system call, after asking (docs/windows.md).
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
