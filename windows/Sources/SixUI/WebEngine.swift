import CWebKit2
import Foundation
import WinSDK

/// Starts the real engine once, and hands out one `RailWebView` per live column. The WebKit2 C API
/// this wraps — `WKContext`, `WKPage`, `WKView` — is the same family WebKitGTK's C API descends
/// from, and this sequence of calls is the one `../sixty`'s MiniBrowserSwift prototype uses.
///
/// Whether the page lands where it is drawn is decided outside this file, by the DPI awareness
/// `main.swift` declares — read that before touching anything here about scale.
@MainActor
enum WebEngine {
    private static var context: WKContextRef?
    private static var websiteDataStore: WKWebsiteDataStoreRef?

    private static func ensureStarted() {
        guard context == nil else { return }
        // Non-persistent: nothing here is wired to survive a relaunch yet (see docs/windows.md),
        // and a non-persistent store sidesteps an on-disk cache a crashed WebProcess could leave
        // corrupt, poisoning every launch after it the same way.
        websiteDataStore = WKWebsiteDataStoreCreateNonPersistentDataStore()
        context = WKContextCreateWithConfiguration(WKContextConfigurationCreate())
    }

    /// A new `WKView`, hosted as a child of `parent` at `frame` (client coordinates). `nil` only if
    /// WebKit itself refuses — there is nothing more specific to say without deeper diagnostics.
    static func makeView(parent: HWND, frame: RECT) -> RailWebView? {
        ensureStarted()
        guard let context, let websiteDataStore else { return nil }

        let pageConfiguration = WKPageConfigurationCreate()
        WKPageConfigurationSetWebsiteDataStore(pageConfiguration, websiteDataStore)
        WKPageConfigurationSetContext(pageConfiguration, context)
        let preferences = WKPreferencesCreate()
        // Software compositing, deliberately. The accelerated path draws into the window in real
        // device pixels, ignoring the DPI virtualization `main.swift` leans on, and puts the page at
        // two thirds size in a corner of its card; the blit path honours it. Costs GPU compositing,
        // buys a page that is where it looks like it is.
        WKPreferencesSetAcceleratedCompositingEnabled(preferences, false)
        WKPageConfigurationSetPreferences(pageConfiguration, preferences)

        // `frame` as given: `RailLiveView.bodyRect` comes straight from `NiriLayout`'s viewport,
        // which is `WM_SIZE`'s own client size, and WebKit lays the page out in exactly those units.
        var rect = WKRectCompat(left: frame.left, top: frame.top, right: frame.right, bottom: frame.bottom)
        guard let view = WKViewCreate(&rect, pageConfiguration, UnsafeMutableRawPointer(parent)) else { return nil }
        WKViewSetIsInWindow(view, true)
        WKViewWindowAncestryDidChange(view)
        guard let page = WKViewGetPage(view) else { return nil }

        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            let dpi = GetDpiForWindow(parent)
            let ourScale = dpi > 0 ? Double(dpi) / 96.0 : 1.0
            let message = "[six] webkit: dpi=\(dpi) ourScale=\(ourScale) " +
                "backingScaleFactor=\(WKPageGetBackingScaleFactor(page)) rect=\(frame)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        return RailWebView(view: view, page: page)
    }
}

/// One live column: the `WKView` (a real child `HWND` WebKit owns and draws into) and the `WKPage`
/// behind it. `RailWindow` positions it over a card's body and shows/hides it as focus moves;
/// nothing here knows the rail exists.
@MainActor
final class RailWebView {
    let view: WKViewRef
    let page: WKPageRef
    /// Told the page's title whenever a navigation finishes — `RailWindow` forwards this straight
    /// into `RailModel`, which is the only thing that knows what a title is *for*.
    var onTitleChange: ((String) -> Void)?
    /// Told the page's own URL whenever a navigation finishes — a redirect or an in-page link click
    /// moves this away from whatever `load(_:)` was last called with, and the address bar needs to
    /// track that, not just what it was told to load.
    var onURLChange: ((String) -> Void)?

    init(view: WKViewRef, page: WKPageRef) {
        self.view = view
        self.page = page
        installNavigationClient()
    }

    /// The struct only needs to be valid for the one call below — WebKit copies it, the way any
    /// "set a client vtable" C API does, so unlike `RailWindow`'s own `GWLP_USERDATA` dance this
    /// needs no address of its own to keep stable. `clientInfo` is that same dance in miniature:
    /// the one piece of state the free-function callback needs to find its way back to `self`.
    private func installNavigationClient() {
        var client = WKPageNavigationClientV3()
        client.base.version = 3
        // `const void *` imports as the immutable `UnsafeRawPointer`, not `Unmanaged.toOpaque()`'s
        // `UnsafeMutableRawPointer` — the class instance behind it is never mutated through this
        // pointer either way, only read back to find `self` again.
        client.base.clientInfo = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        client.didFinishNavigation = { _, _, _, clientInfo in
            guard let clientInfo else { return }
            let webView = Unmanaged<RailWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleFinishedNavigation() }
        }
        WKPageSetPageNavigationClient(page, &client.base)
    }

    private func handleFinishedNavigation() {
        let title = Self.string(from: WKPageCopyTitle(page))
        if !title.isEmpty { onTitleChange?(title) }
        if let activeURL = WKPageCopyActiveURL(page) {
            let urlString = Self.string(from: WKURLCopyString(activeURL))
            if !urlString.isEmpty { onURLChange?(urlString) }
        }
    }

    private static func string(from ref: WKStringRef?) -> String {
        guard let ref else { return "" }
        let size = WKStringGetMaximumUTF8CStringSize(ref)
        var buffer = [Int8](repeating: 0, count: size)
        _ = WKStringGetUTF8CString(ref, &buffer, size)
        return buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }
    }

    /// `WKViewGetWindow` hands back `void *` rather than `HWND` — the header avoids `<windows.h>`
    /// types at the C boundary entirely (see CWebKit2's header comment) — so this is a type-pun of
    /// an opaque pointer, not a dereference; `HWND` and `void *` are the same bit pattern.
    var hwnd: HWND? {
        WKViewGetWindow(view).map { $0.assumingMemoryBound(to: HWND__.self) }
    }

    func load(_ urlString: String) {
        let wkURL = urlString.withCString { WKURLCreateWithUTF8CString($0) }
        WKPageLoadURL(page, wkURL)
    }

    func setFrame(_ rect: RECT) {
        guard let hwnd else { return }
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    func setVisible(_ visible: Bool) {
        guard let hwnd else { return }
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
    }

    func destroy() {
        guard let hwnd else { return }
        DestroyWindow(hwnd)
    }
}
