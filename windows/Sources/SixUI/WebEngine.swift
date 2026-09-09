import CRailInterop
import CWebKit2
import Foundation
import SixBrowser
import WinSDK

/// Starts the real engine once, and hands out one `RailWebView` per live column. The WebKit2 C API
/// this wraps — `WKContext`, `WKPage`, `WKView` — is the same family WebKitGTK's C API descends
/// from, and this sequence of calls is the one `../sixty`'s MiniBrowserSwift prototype uses.
///
/// Everything about display scale on this front is `RailWebView.installScaleShim` — read that
/// before touching the rect handed to `WKViewCreate` or the window procedure in front of it.
@MainActor
enum WebEngine {
    private static var context: WKContextRef?
    /// One website data store per profile — cookies, local storage and caches, each in the profile's
    /// own folder. This is what a profile *is* on every other front (`Profile.dataStoreID` and a
    /// persistent `WKWebsiteDataStore` on the Mac), and the reason profiles here are more than a
    /// coloured label: sign in to something in one and the other has never heard of it.
    private static var dataStores: [Foundation.UUID: WKWebsiteDataStoreRef] = [:]

    private static func ensureStarted() {
        guard context == nil else { return }
        context = WKContextCreateWithConfiguration(WKContextConfigurationCreate())
    }

    /// The store a profile browses in, made on first use and kept for the run.
    ///
    /// A private profile gets the non-persistent store, which is the whole of what "private" means
    /// here: it exists in memory, it goes when the process does, and nothing of it is written down.
    private static func dataStore(for profile: RailModel.ProfileInfo) -> WKWebsiteDataStoreRef? {
        if let existing = dataStores[profile.id] { return existing }
        let store: WKWebsiteDataStoreRef?
        if profile.isPrivate {
            store = WKWebsiteDataStoreCreateNonPersistentDataStore()
        } else {
            // Every directory is asked for separately: this configuration has no "put it all under
            // here" knob, and one left unset lands in the port's own default, which on Windows is
            // beside the executable — shared by every profile, which is the opposite of the point.
            let configuration = WKWebsiteDataStoreConfigurationCreate()
            let root = profile.storageFolder
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            func directory(_ name: String) -> WKStringRef? {
                let path = root + "\\" + name
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                return path.withCString { WKStringCreateWithUTF8CString($0) }
            }
            WKWebsiteDataStoreConfigurationSetNetworkCacheDirectory(configuration, directory("NetworkCache"))
            WKWebsiteDataStoreConfigurationSetIndexedDBDatabaseDirectory(configuration, directory("IndexedDB"))
            WKWebsiteDataStoreConfigurationSetLocalStorageDirectory(configuration, directory("LocalStorage"))
            WKWebsiteDataStoreConfigurationSetWebSQLDatabaseDirectory(configuration, directory("WebSQL"))
            WKWebsiteDataStoreConfigurationSetCacheStorageDirectory(configuration, directory("CacheStorage"))
            WKWebsiteDataStoreConfigurationSetGeneralStorageDirectory(configuration, directory("Storage"))
            WKWebsiteDataStoreConfigurationSetMediaKeysStorageDirectory(configuration, directory("MediaKeys"))
            WKWebsiteDataStoreConfigurationSetServiceWorkerRegistrationDirectory(
                configuration, directory("ServiceWorkers"))
            WKWebsiteDataStoreConfigurationSetResourceLoadStatisticsDirectory(
                configuration, directory("ResourceLoadStatistics"))
            // The one that is a file rather than a folder, and the one that carries the sessions:
            // two profiles sharing a cookie jar would be two names on one browser.
            let cookies = root + "\\cookies.db"
            WKWebsiteDataStoreConfigurationSetCookieStorageFile(
                configuration, cookies.withCString { WKStringCreateWithUTF8CString($0) })
            store = WKWebsiteDataStoreCreateWithConfiguration(configuration)
        }
        dataStores[profile.id] = store
        return store
    }

    /// A new `WKView`, hosted as a child of `parent` at `frame` (client coordinates), browsing in
    /// `profile`'s own data store. `nil` only if WebKit itself refuses — there is nothing more
    /// specific to say without deeper diagnostics.
    static func makeView(parent: HWND, frame: RECT, profile: RailModel.ProfileInfo) -> RailWebView? {
        ensureStarted()
        guard let context, let websiteDataStore = dataStore(for: profile) else { return nil }

        let pageConfiguration = WKPageConfigurationCreate()
        WKPageConfigurationSetWebsiteDataStore(pageConfiguration, websiteDataStore)
        WKPageConfigurationSetContext(pageConfiguration, context)
        let preferences = WKPreferencesCreate()
        // Software compositing. The accelerated path draws correctly too now that
        // `RailWebView.installScaleShim` has the scales agreeing, but it put a visible layer seam
        // through the middle of a search field; worth revisiting, not worth shipping.
        WKPreferencesSetAcceleratedCompositingEnabled(preferences, false)
        WKPageConfigurationSetPreferences(pageConfiguration, preferences)

        // Created at `frame` divided by the display scale, and grown to the real `frame` by the
        // `setFrame` that follows in `RailLiveView.updateLiveView` — which is what puts the first
        // `WM_SIZE` through the shim below. See `installScaleShim` for why the view is told a
        // smaller size than the window it lives in.
        let dpi = GetDpiForWindow(parent)
        let scale = dpi > 0 ? Double(dpi) / 96.0 : 1.0
        var rect = WKRectCompat(
            left: frame.left, top: frame.top,
            right: frame.left + Int32(Double(frame.right - frame.left) / scale),
            bottom: frame.top + Int32(Double(frame.bottom - frame.top) / scale)
        )
        guard let view = WKViewCreate(&rect, pageConfiguration, UnsafeMutableRawPointer(parent)) else { return nil }
        WKViewSetIsInWindow(view, true)
        WKViewWindowAncestryDidChange(view)
        guard let page = WKViewGetPage(view) else { return nil }

        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
            let message = "[six] webkit: dpi=\(dpi) ourScale=\(scale) " +
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
        installScaleShim()
    }

    /// Hand-rolled mixed-DPI hosting: the only way found to get a page that is at once correctly
    /// sized, correctly clickable and sharp on a scaled display.
    ///
    /// WebKit's Windows port renders at `viewSize × deviceScaleFactor` and then presents that
    /// surface into the window one backing pixel to one, with **no downscale**. Both inputs come off
    /// this same `HWND` — the client rect, and the DPI Windows reports for it — so they move
    /// together and no DPI awareness mode changes their product. A window procedure in front of the
    /// view can change it: tell WebKit its client area is `real / scale`, and the surface it renders
    /// comes out at exactly the window's real pixel count. Windows' own `DPI_HOSTING_BEHAVIOR_MIXED`
    /// does the same first half and then gives the benefit straight back by bitmap-scaling the
    /// result; this does not, which is the whole point.
    ///
    /// Only `WM_SIZE` is rewritten. Mouse messages are deliberately left alone: WebKit already
    /// divides an event's client coordinates by the device scale, which is exactly the factor
    /// between where a CSS pixel is drawn and where it is — dividing them here too moved every click
    /// by 1.5x again, measured, a click on a grid's middle cell landing two cells away.
    ///
    /// Installed on every view, not only on scaled displays: at 100% it divides by one and changes
    /// nothing, which is less to reason about than a front that behaves differently per monitor.
    private func installScaleShim() {
        guard let hwnd else { return }
        let previous = GetWindowLongPtrW(hwnd, GWLP_WNDPROC)
        MainActor.assumeIsolated {
            scaleShims[shimKey(hwnd)] = unsafeBitCast(previous, to: WNDPROC.self)
        }
        let shimProc: WNDPROC = webViewScaleProc
        _ = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, unsafeBitCast(shimProc, to: LONG_PTR.self))
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
        if !title.isEmpty { onTitleChange?(title) }
        if !url.isEmpty { onURLChange?(url) }
    }

    /// What the page says it is, asked rather than remembered.
    ///
    /// `didFinishNavigation` is not the moment a title exists: a page that sets `<title>` from a
    /// script, or simply late, finishes its navigation with the *previous* title still in place —
    /// which showed up here as a card still labelled DuckDuckGo with example.com in it. `RailWindow`
    /// polls these on a timer for that reason, the same "poll from Swift for anything that must
    /// wait" CLAUDE.md settles on for page state.
    var title: String { Self.string(from: WKPageCopyTitle(page)) }

    var url: String {
        guard let activeURL = WKPageCopyActiveURL(page) else { return "" }
        return Self.string(from: WKURLCopyString(activeURL))
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

    /// What the top bar's three navigation buttons act on, and what tells them whether they can —
    /// the state is read live rather than tracked, because WebKit's back-forward list is the truth
    /// and nothing here would be told when a page pushes onto it.
    var canGoBack: Bool { WKPageCanGoBack(page) }
    var canGoForward: Bool { WKPageCanGoForward(page) }
    func goBack() { WKPageGoBack(page) }
    func goForward() { WKPageGoForward(page) }
    func reload() { WKPageReload(page) }

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
        scaleShims[shimKey(hwnd)] = nil
        DestroyWindow(hwnd)
    }
}

/// One live view's saved window procedure, keyed by `HWND` rather than parked in `GWLP_USERDATA`,
/// which belongs to WebKit on this window.
@MainActor
private var scaleShims: [UInt: WNDPROC] = [:]

private nonisolated func shimKey(_ hwnd: HWND) -> UInt { UInt(bitPattern: Int(bitPattern: hwnd)) }

/// `nonisolated` for the same reason every other `WNDPROC` here is: a C function pointer carries no
/// actor isolation. See `RailWebView.installScaleShim` for what it is rewriting and why.
private nonisolated func webViewScaleProc(
    _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    guard let hwnd else { return DefWindowProcW(hwnd, message, wParam, lParam) }
    let key = shimKey(hwnd)
    let original = MainActor.assumeIsolated { scaleShims[key] }
    guard let original else { return DefWindowProcW(hwnd, message, wParam, lParam) }
    // Read live rather than remembered: this is the one place that would otherwise go wrong when the
    // window is dragged to a display at a different scale.
    let dpi = GetDpiForWindow(hwnd)
    let scale = dpi > 0 ? Double(dpi) / 96.0 : 1.0

    var forwarded = lParam
    if Int32(message) == WM_SIZE {
        let width = Int32(Double(SixRailLoWord(lParam)) / scale)
        let height = Int32(Double(SixRailHiWord(lParam)) / scale)
        forwarded = SixRailPackWords(width, height)
    }
    return CallWindowProcW(original, hwnd, message, wParam, forwarded)
}
