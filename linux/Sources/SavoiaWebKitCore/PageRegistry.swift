import CWebKitGTK
import Foundation

/// Which live page belongs to which column.
///
/// A declarative front hands the view tree a *description* of a page, and the widget behind it is
/// adwaita's to own. But back, forward and reload act on that widget, and there is nowhere in a
/// value-typed description to reach it — so the pages register themselves here as they are built,
/// and the model asks by tab.
///
/// The Mac has the same seam and solves it the same way: `BrowserTab.page` is the one place that
/// knows how to reach a live page, and everything that *talks* to one goes through it. This is that
/// place on Linux.
@MainActor
public enum PageRegistry {
    private static var pages: [UUID: UnsafeMutablePointer<WebKitWebView>] = [:]

    /// Taken as an `OpaquePointer` because that is what adwaita's `ViewStorage` hands out, and kept
    /// as a `WebKitWebView*` because that is what webkit's own functions want. The two spellings are
    /// the same pointer; which one a type gets depends on whether its struct is public in the
    /// headers, and it varies type by type.
    public static func register(_ pointer: OpaquePointer, for tabID: UUID) {
        pages[tabID] = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: WebKitWebView.self)
    }

    public static func forget(_ tabID: UUID) { pages[tabID] = nil }

    public static func page(for tabID: UUID) -> UnsafeMutablePointer<WebKitWebView>? { pages[tabID] }

    // MARK: What the chrome asks of a page

    public static func goBack(_ tabID: UUID) {
        guard let page = pages[tabID] else { return }
        webkit_web_view_go_back(page)
    }

    public static func goForward(_ tabID: UUID) {
        guard let page = pages[tabID] else { return }
        webkit_web_view_go_forward(page)
    }

    public static func reload(_ tabID: UUID) {
        guard let page = pages[tabID] else { return }
        webkit_web_view_reload(page)
    }

    public static func canGoBack(_ tabID: UUID) -> Bool {
        guard let page = pages[tabID] else { return false }
        return webkit_web_view_can_go_back(page) != 0
    }

    public static func canGoForward(_ tabID: UUID) -> Bool {
        guard let page = pages[tabID] else { return false }
        return webkit_web_view_can_go_forward(page) != 0
    }

    /// The address the page is actually on, which is not always the one it was asked for — a
    /// redirect, or a link followed inside the page.
    public static func url(of tabID: UUID) -> URL? {
        guard let page = pages[tabID],
              let uri = webkit_web_view_get_uri(page).map({ String(cString: $0) }) else { return nil }
        return URL(string: uri)
    }
}
