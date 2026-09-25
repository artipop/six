import CStripInterop
import CWebKit2
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// Starts the real engine once, and hands out one `StripWebView` per live column. The WebKit2 C API
/// this wraps — `WKContext`, `WKPage`, `WKView` — is the same family WebKitGTK's C API descends
/// from, and this sequence of calls is the one `../sixty`'s MiniBrowserSwift prototype uses.
///
/// Everything about display scale on this front is `StripWebView.installScaleShim` — read that
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
    private static func dataStore(for profile: StripModel.ProfileInfo) -> WKWebsiteDataStoreRef? {
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
    static func makeView(parent: HWND, frame: RECT, profile: StripModel.ProfileInfo) -> StripWebView? {
        ensureStarted()
        guard let context, let websiteDataStore = dataStore(for: profile) else { return nil }

        let pageConfiguration = WKPageConfigurationCreate()
        WKPageConfigurationSetWebsiteDataStore(pageConfiguration, websiteDataStore)
        WKPageConfigurationSetContext(pageConfiguration, context)
        let preferences = WKPreferencesCreate()
        // Software compositing. The accelerated path draws correctly too now that
        // `StripWebView.installScaleShim` has the scales agreeing, but it put a visible layer seam
        // through the middle of a search field; worth revisiting, not worth shipping.
        WKPreferencesSetAcceleratedCompositingEnabled(preferences, false)
        // `navigator.mediaDevices`, for an engine that has it. **Playwright's does not**: MediaStream
        // is compiled out of its WebCore — `JSMediaStream`, `JSMediaDevices` and `UserMediaRequest`
        // appear nowhere in `WebCore.dll` while `JSHTMLDivElement` does, and a page reads
        // `MediaStream`, `RTCPeerConnection` and `navigator.mediaDevices` as `undefined` whatever
        // this or the `MediaStreamEnabled` feature key say (both measured). So on today's engine no
        // page ever asks, and `StripWebView.onMediaRequest` is wiring for the WebKit that is not
        // Playwright's (docs/todo.md) — `SIX_PERMISSION_SELFTEST` exercises everything above it.
        WKPreferencesSetMediaDevicesEnabled(preferences, true)
        // `<a download>`: the page saying a link is a file to keep, not a page to show.
        WKPreferencesSetDownloadAttributeEnabled(preferences, true)
        // A camera and a microphone that are not there, for testing the question and its answer on
        // a machine that has neither — the Linux front's `SIX_MOCK_CAPTURE`, spelled the same.
        if ProcessInfo.processInfo.environment["SIX_MOCK_CAPTURE"] == "1" {
            WKPreferencesSetMockCaptureDevicesEnabled(preferences, true)
        }
        WKPageConfigurationSetPreferences(pageConfiguration, preferences)
        return makeView(parent: parent, frame: frame, configuration: pageConfiguration)
    }

    /// A view on a configuration already made: `makeView(parent:frame:profile:)`'s, or the one WebKit
    /// hands `createNewPage` for a window a page opened. That second one is why this is separate — it
    /// carries the opener, so the new page is related to the one that asked (`window.opener`, a
    /// sign-in popup's way back) and browses in that page's store without being told which.
    static func makeView(parent: HWND, frame: RECT, configuration pageConfiguration: WKPageConfigurationRef?) -> StripWebView? {
        ensureStarted()

        // Created at `frame` divided by the display scale, and grown to the real `frame` by the
        // `setFrame` that follows in `StripLiveView.updateLiveView` — which is what puts the first
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

        return StripWebView(view: view, page: page)
    }

    /// The view `StripSandbox` runs six's own programs in: no profile, no persistence, and allowed
    /// to read the files sitting beside the page it loads.
    ///
    /// The two preferences are the whole difference from a browsing view, and both are about the
    /// same thing — the page is a `file:` document that has to `fetch()` a wasm module and a model
    /// out of the folder it lives in, which the same-origin rules forbid a `file:` document by
    /// default. Nothing but six's own payload is ever loaded here, so the relaxation reaches nothing
    /// a site could take advantage of.
    static func makeSandboxView(parent: HWND) -> StripWebView? {
        ensureStarted()
        guard let context, let websiteDataStore = WKWebsiteDataStoreCreateNonPersistentDataStore() else {
            return nil
        }
        let pageConfiguration = WKPageConfigurationCreate()
        WKPageConfigurationSetWebsiteDataStore(pageConfiguration, websiteDataStore)
        WKPageConfigurationSetContext(pageConfiguration, context)
        let preferences = WKPreferencesCreate()
        WKPreferencesSetAcceleratedCompositingEnabled(preferences, false)
        WKPreferencesSetFileAccessFromFileURLsAllowed(preferences, true)
        WKPreferencesSetUniversalAccessFromFileURLsAllowed(preferences, true)
        WKPageConfigurationSetPreferences(pageConfiguration, preferences)

        var rect = WKRectCompat(left: 0, top: 0, right: 1, bottom: 1)
        guard let view = WKViewCreate(&rect, pageConfiguration, UnsafeMutableRawPointer(parent)) else {
            return nil
        }
        // Told it is in a window although the window is off-screen and never shown: WebKit throttles
        // a page it believes nobody can see, and this one is working for its living.
        WKViewSetIsInWindow(view, true)
        WKViewWindowAncestryDidChange(view)
        guard let page = WKViewGetPage(view) else { return nil }
        let sandbox = StripWebView(view: view, page: page)
        // Six's own programs, not somebody's page: a `file:` document that does not load is a
        // failure its driver has to see, not an error page that would look to it like a load.
        sandbox.showsFailures = false
        return sandbox
    }
}

/// One live column: the `WKView` (a real child `HWND` WebKit owns and draws into) and the `WKPage`
/// behind it. `StripWindow` positions it over a card's body and shows/hides it as focus moves;
/// nothing here knows the row exists.
@MainActor
final class StripWebView {
    let view: WKViewRef
    let page: WKPageRef
    /// Told the page's title whenever a navigation finishes — `StripWindow` forwards this straight
    /// into `StripModel`, which is the only thing that knows what a title is *for*.
    var onTitleChange: ((String) -> Void)?
    /// Told the page's own URL whenever a navigation finishes — a redirect or an in-page link click
    /// moves this away from whatever `load(_:)` was last called with, and the address bar needs to
    /// track that, not just what it was told to load.
    var onURLChange: ((String) -> Void)?
    /// Told when a navigation has finished, whatever it was. `StripSandbox` waits on this — it is
    /// how "the page is loaded and its scripts have run" is spelled through the C API.
    var onFinishNavigation: (() -> Void)?
    /// Told when the page asks for the camera or the microphone. Answer through the request, now or
    /// after a bar has been up for a while — but always answer: the page's `getUserMedia()` promise
    /// is suspended until then. Nobody listening is a no.
    var onMediaRequest: ((MediaRequest) -> Void)?

    /// A site asking a page for a device, in the vocabulary `SitePermissions` already speaks.
    struct MediaRequest {
        /// `https://example.com`, the way the Mac files an answer: scheme, host, and a port only
        /// when it is not the scheme's own.
        let origin: String
        let camera: Bool
        let microphone: Bool
        let answer: (Bool) -> Void
    }

    /// Told when the page calls `alert()`, `confirm()` or `prompt()`. The page's JavaScript is
    /// suspended until `answer` is called — `nil` is Cancel, anything else is OK and, for a prompt,
    /// what was typed. Nobody listening is WebKit's own answer: the alert gone unseen, the confirm
    /// refused, the prompt left null.
    var onDialog: ((PageDialog) -> Void)?

    struct PageDialog {
        enum Kind { case alert, confirm, prompt(defaultText: String) }
        /// Who is speaking: the host of the frame's origin, a subframe's own rather than the page's.
        let host: String
        let message: String
        let kind: Kind
        let answer: (String?) -> Void
    }

    /// Told when an `<input type=file>` is clicked. `answer` takes the files chosen, or `nil` for
    /// Cancel; until then the input waits.
    var onChooseFiles: ((FileChoice) -> Void)?

    struct FileChoice {
        let allowsMultiple: Bool
        /// `webkitdirectory`: a folder rather than files.
        let allowsDirectories: Bool
        /// From the input's `accept`, without the dots. MIME types are not among them.
        let extensions: [String]
        let answer: ([URL]?) -> Void
    }

    /// Told when the page opens a window of its own — `window.open`, a `target=_blank` link — with the
    /// configuration WebKit wants it made on and the address it is for. Answer with the view that is
    /// that window, made on that configuration (`WebEngine.makeView(parent:frame:configuration:)`), or
    /// `nil` to refuse; the new page loads its request by itself.
    var onCreatePage: ((WKPageConfigurationRef, String) -> StripWebView?)?

    /// Told when a navigation has become a download — the page's own `<a download>`, or a response
    /// that is a file. The transfer is WebKit's, with the page's cookies already on it; what the row
    /// owes it is a client (`StripDownloads.adopt`).
    var onDownload: ((WKDownloadRef) -> Void)?

    /// Told when the page wants an address that is somebody else's app's (`ExternalScheme`), with
    /// whether a click was behind it. The navigation has already been refused; opening the app is the
    /// row's decision, and it asks first.
    var onExternalLink: ((String, Bool) -> Void)?

    /// `true` takes the navigation away from the page: the address is not one a window shows.
    func handOff(_ address: String, gesture: Bool) -> Bool {
        guard let url = URL(string: address), ExternalScheme.isExternal(url) else { return false }
        onExternalLink?(address, gesture)
        return true
    }

    /// Told when Open Link Behind is chosen in the page's context menu, with the link it was opened on.
    var onOpenLinkBehind: ((String) -> Void)?
    /// The link under the pointer when the context menu was opened, `nil` when it was not on one.
    private var menuLink: String?

    /// Told when the page closes itself. WebKit allows `window.close()` only to a window a script
    /// opened, so this is a popup going away when it is done — a sign-in window, usually.
    var onClose: (() -> Void)?

    /// The link under the pointer as the page last reported it, `nil` over anything else. What a middle
    /// click or a `Ctrl`-click is read against: WebKit's C API tells a navigation nothing about the
    /// button or the keys behind it, so the row catches those clicks on their way in (`route`).
    private(set) var hoveredLink: String?

    /// Between a navigation starting and it finishing or failing — what the loading line is drawn for.
    private(set) var isLoading = false
    /// WebKit's own guess at how far the page has got, `0…1`, read on the page-state timer.
    var estimatedProgress: Double { WKPageGetEstimatedProgress(page) }
    /// The page on screen is six's "this page didn't open", not the site's. Such a page is not a
    /// visit, and the navigation that put it there is not a load anybody was waiting for.
    private(set) var isShowingFailure = false
    /// Set just before the failure page is loaded, so the navigation it starts is known for what it is.
    private var loadingFailurePage = false
    /// The navigation that started last, by the address of its `WKNavigationRef`. A failure belongs
    /// to the page only if it is this one's (`handleFailedNavigation`).
    private var currentNavigation: Int?
    /// False for the sandbox views, whose pages are six's own programs (`makeSandboxView`).
    var showsFailures = true

    /// The Cancel for every question still on screen or in a queue, so a view torn down in the middle
    /// of one lets its page go rather than leaving it suspended — and the listener retained — for
    /// the life of the process.
    private var owed: [Foundation.UUID: () -> Void] = [:]

    /// Where `setFrame` and `setVisible` last put the view, so a repaint that asks again for the same
    /// thing costs nothing. Every visible column is re-placed on every repaint, and a `MoveWindow`
    /// with `bRepaint` set repaints the whole page each time.
    private var placedFrame: RECT?
    private var isShown: Bool?

    init(view: WKViewRef, page: WKPageRef) {
        self.view = view
        self.page = page
        installNavigationClient()
        installUIClient()
        installContextMenuClient()
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
    /// "set a client vtable" C API does, so unlike `StripWindow`'s own `GWLP_USERDATA` dance this
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
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleFinishedNavigation() }
        }
        // Navigations are told apart by the address of their `WKNavigationRef`, kept as a number: it
        // is compared, never followed, so nothing needs retaining for it.
        client.didStartProvisionalNavigation = { _, navigation, _, clientInfo in
            guard let clientInfo else { return }
            let started = navigation.map { Int(bitPattern: UnsafeRawPointer($0)) }
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleStartedNavigation(started) }
        }
        client.didFailProvisionalNavigation = { _, navigation, error, _, clientInfo in
            guard let clientInfo else { return }
            nonisolated(unsafe) let failure = error
            let failed = navigation.map { Int(bitPattern: UnsafeRawPointer($0)) }
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleFailedNavigation(failure, navigation: failed, provisional: true) }
        }
        client.didFailNavigation = { _, navigation, error, _, clientInfo in
            guard let clientInfo else { return }
            nonisolated(unsafe) let failure = error
            let failed = navigation.map { Int(bitPattern: UnsafeRawPointer($0)) }
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleFailedNavigation(failure, navigation: failed, provisional: false) }
        }
        // A file rather than a page. Left to WebKit's default, both of these answer "show it": a
        // `<a download>` link opens the file as a page, and a zip or an attachment becomes a blank
        // column — the Mac's table in links.md, row for row, before six answered them there.
        client.decidePolicyForNavigationAction = { _, action, listener, _, clientInfo in
            guard let listener else { return }
            if let action, WKNavigationActionShouldPerformDownload(action) {
                return WKFramePolicyListenerDownload(listener)
            }
            // Somebody else's app — `mailto:`, `magnet:`, whatever an app claimed. Never the page's
            // to load, and never the page's to launch either: it is handed up with whether a click
            // was behind it, and the row asks (`offerExternalLink`). A frame's navigation is asked
            // here too, which is how an `<iframe src="ms-settings:">` is stopped with the rest.
            nonisolated(unsafe) let asked = action
            let gesture = action.map { WKNavigationActionHasUnconsumedUserGesture($0) } ?? false
            var handedOff = false
            if let clientInfo {
                let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    handedOff = webView.handOff(StripWebView.address(of: asked), gesture: gesture)
                }
            }
            if handedOff {
                WKFramePolicyListenerIgnore(listener)
            } else {
                WKFramePolicyListenerUse(listener)
            }
        }
        client.decidePolicyForNavigationResponse = { _, navigationResponse, listener, _, _ in
            guard let listener else { return }
            guard let navigationResponse else { return WKFramePolicyListenerUse(listener) }
            var attachment = false
            if let response = WKNavigationResponseCopyResponse(navigationResponse) {
                attachment = WKURLResponseIsAttachment(response)
                WKRelease(UnsafeRawPointer(response))
            }
            if attachment || !WKNavigationResponseCanShowMIMEType(navigationResponse) {
                WKFramePolicyListenerDownload(listener)
            } else {
                WKFramePolicyListenerUse(listener)
            }
        }
        client.navigationActionDidBecomeDownload = { _, _, download, clientInfo in
            guard let clientInfo, let download else { return }
            nonisolated(unsafe) let started = download
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.onDownload?(started) }
        }
        client.navigationResponseDidBecomeDownload = { _, _, download, clientInfo in
            guard let clientInfo, let download else { return }
            nonisolated(unsafe) let started = download
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.onDownload?(started) }
        }
        // The context menu's Download Linked File: a download made by the menu, with no navigation
        // behind it, so it arrives here rather than through either of the two above.
        client.contextMenuDidCreateDownload = { _, download, clientInfo in
            guard let clientInfo, let download else { return }
            nonisolated(unsafe) let started = download
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.onDownload?(started) }
        }
        WKPageSetPageNavigationClient(page, &client.base)
    }

    /// The menu over a page is WebKit's, and on this port it is a real one: over a link it offers
    /// Open Link, Open Link in New Window, Download Linked File and Copy Link — measured, reading the
    /// menu a right-click put up. The Mac had to throw WebKit's menu away and build its own, because
    /// in a SwiftUI `WebView` two of those four are dead; here they are not, since the UI client
    /// (`createNewPage`) and the downloads (`contextMenuDidCreateDownload`) are wired. So the menu
    /// stays WebKit's, with the Mac's one item it lacks put in after Open Link in New Window: **Open
    /// Link Behind**. The Mac's Open Link Beside is not offered — nothing on this front makes a
    /// window share its column yet.
    private func installContextMenuClient() {
        var client = WKPageContextMenuClientV2()
        client.base.version = 2
        client.base.clientInfo = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        client.getContextMenuFromProposedMenu = { _, proposed, newMenu, hit, _, clientInfo in
            guard let newMenu else { return }
            nonisolated(unsafe) let offered = proposed
            nonisolated(unsafe) let result = hit
            nonisolated(unsafe) var made: WKArrayRef?
            if let clientInfo {
                let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
                MainActor.assumeIsolated { made = webView.menu(from: offered, over: result) }
            } else if let offered {
                // No client to ask: WebKit's own menu, as it was.
                WKRetain(UnsafeRawPointer(offered))
                made = offered
            }
            // At +1, and always something: WebKit adopts what it is handed, and treats nothing as an
            // empty menu rather than as "use your own".
            newMenu.pointee = made
        }
        client.customContextMenuItemSelected = { _, item, clientInfo in
            guard let clientInfo, let item else { return }
            let tag = WKContextMenuItemGetTag(item)
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.menuItemChosen(tag) }
        }
        WKPageSetPageContextMenuClient(page, &client.base)
    }

    /// Six's own items live above WebKit's application base, where WebKit hands their choice back
    /// through `customContextMenuItemSelected` instead of acting on them itself.
    private static let openLinkBehindTag = WKContextMenuItemTag(kWKContextMenuItemBaseApplicationTag) + 1

    /// WebKit's proposed menu with Open Link Behind added over a link. The link is read now, from the
    /// hit test the menu was opened on, because by the time an item is chosen the pointer has moved.
    private func menu(from proposed: WKArrayRef?, over hit: WKHitTestResultRef?) -> WKArrayRef? {
        menuLink = Self.link(in: hit)
        var items: [UnsafeRawPointer?] = []
        if let proposed {
            for index in 0..<WKArrayGetSize(proposed) { items.append(WKArrayGetItemAtIndex(proposed, index)) }
        }
        var added: WKContextMenuItemRef?
        if let link = menuLink, onOpenLinkBehind != nil, Self.opensInColumn(link),
           let title = Self.wkString("Open Link Behind") {
            added = WKContextMenuItemCreateAsAction(Self.openLinkBehindTag, title, true)
            WKRelease(UnsafeRawPointer(title))
            let newWindow = WKContextMenuItemTag(kWKContextMenuItemTagOpenLinkInNewWindow)
            let after = items.firstIndex { item in
                item.map { WKContextMenuItemGetTag(OpaquePointer($0)) == newWindow } ?? false
            }
            items.insert(added.map { UnsafeRawPointer($0) }, at: after.map { $0 + 1 } ?? items.count)
        }
        // `WKArrayCreate` retains what it holds, so the item made here is let go once it is in.
        let array = items.withUnsafeMutableBufferPointer { WKArrayCreate($0.baseAddress, $0.count) }
        if let added { WKRelease(UnsafeRawPointer(added)) }
        return array
    }

    private func menuItemChosen(_ tag: WKContextMenuItemTag) {
        guard tag == Self.openLinkBehindTag, let link = menuLink else { return }
        onOpenLinkBehind?(link)
    }

    /// What a new column can show — the same answer `StripNewWindows.opensInColumn` gives a middle
    /// click, so the menu does not offer to open behind what a column cannot open.
    private static func opensInColumn(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "about", "data", "blob"].contains(scheme)
    }

    private func handleFinishedNavigation() {
        isLoading = false
        if !title.isEmpty { onTitleChange?(title) }
        if !url.isEmpty { onURLChange?(url) }
        onFinishNavigation?()
    }

    private func handleStartedNavigation(_ navigation: Int?) {
        currentNavigation = navigation
        if loadingFailurePage {
            loadingFailurePage = false
            isShowingFailure = true
        } else {
            isShowingFailure = false
            isLoading = true
        }
    }

    /// A load that did not happen, answered the way the Mac's `BrowserTab.noteFailure` answers it —
    /// with the same two things that are not failures.
    ///
    /// Only a *provisional* failure gets a page: a page that committed and then failed has something
    /// of its own on screen, and taking it away to say so would be worse than the failure.
    private func handleFailedNavigation(_ error: WKErrorRef?, navigation: Int?, provisional: Bool) {
        // A navigation that is no longer the page's latest failed: something newer has started, and
        // this says nothing about it — not that it stopped loading, and certainly not that it failed.
        // Measured: a page going somewhere else while a slow address was still connecting had that
        // first navigation fail a moment later, and the page put up on top of it cancelled the new
        // one, so the window ended on "This page didn't open" for an address nobody was waiting for.
        if let navigation, let currentNavigation, navigation != currentNavigation { return }
        isLoading = false
        guard showsFailures, provisional, let error else { return }
        let domain = Self.takeString(WKErrorCopyDomain(error))
        let code = Int(WKErrorGetErrorCode(error))
        // Cancelled is not a failure: `stopLoading` looks like this, and so does a navigation that
        // succeeded somewhere else. The Mac's spelling, and then this port's: WebKit's network layer
        // here is curl, not `CFNetwork`, and says "cancelled" as `WebKitErrorDomain` 302 — the
        // superseded navigation above came back as exactly that.
        if domain == "NSURLErrorDomain", code == -999 { return }
        // WebKit's own words for the same thing: a policy that sent the request elsewhere (101, 102
        // — a download, a new window), a plugin that took the load (203), and the network's cancel.
        if domain == "WebKitErrorDomain", [101, 102, 203, 302].contains(code) { return }
        let address: String = WKErrorCopyFailingURL(error).map { url in
            defer { WKRelease(UnsafeRawPointer(url)) }
            return Self.takeString(WKURLCopyString(url))
        } ?? ""
        // The domain and the code, which say what kind of failure; never the address, which says
        // where somebody was going.
        Log.info(.pages, "a page did not load: \(domain) \(code)")
        guard !address.isEmpty else { return }
        let message = Self.takeString(WKErrorCopyLocalizedDescription(error))
        showFailure(address: address, message: message, detail: "\(domain) \(code)")
    }

    /// Six's "this page didn't open", in place of the page that did not.
    ///
    /// `WKPageLoadAlternateHTMLString`, which is what the call is for: the page shown is six's, but
    /// the back-forward item and the address stay the unreachable one, so going back and forward
    /// passes through it the way it would through the site. The Mac draws `PageFailureView` over the
    /// window instead; the words are its words.
    private func showFailure(address: String, message: String, detail: String) {
        guard let html = Self.wkString(Self.failurePage(address: address, message: message, detail: detail)) else { return }
        defer { WKRelease(UnsafeRawPointer(html)) }
        guard let unreachable = address.withCString({ WKURLCreateWithUTF8CString($0) }) else { return }
        defer { WKRelease(UnsafeRawPointer(unreachable)) }
        loadingFailurePage = true
        WKPageLoadAlternateHTMLString(page, html, nil, unreachable)
    }

    /// The Mac's `PageFailureView`, as a page: what happened, where, what six can say about it, a
    /// way to try again, and — demoted, at the bottom — the system's own sentence, which is the thing
    /// to paste into a search. Its title is the host, so the card keeps saying where it was going.
    /// `color-scheme` and the system colours, so it is dark when Windows is.
    private static func failurePage(address: String, message: String, detail: String) -> String {
        let host = URL(string: address)?.host() ?? ""
        let shown = escape(host.isEmpty ? address : host)
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
            <title>\(shown)</title><style>
            html,body{height:100%;margin:0}
            body{display:flex;align-items:center;justify-content:center;font:15px "Segoe UI",system-ui,sans-serif;background:Canvas;color:CanvasText}
            main{max-width:460px;padding:0 28px}
            .mark{font-size:34px;opacity:.55}
            h1{font-size:22px;font-weight:600;margin:14px 0 6px}
            .host{font-family:Consolas,monospace;opacity:.65;margin:0 0 14px;word-break:break-all}
            p{opacity:.75;margin:0 0 18px}
            button{font:inherit;padding:6px 16px;border-radius:6px}
            .detail{font-size:12px;opacity:.45;margin-top:18px;word-break:break-word}
            </style></head><body><main>
            <div class="mark">&#9888;</div>
            <h1>This page didn&#8217;t open</h1>
            <div class="host">\(shown)</div>
            <p>six could not reach this address.</p>
            <button id="again" data-url="\(escape(address))">Try Again</button>
            <div class="detail">\(escape(message)) (\(escape(detail)))</div>
            </main><script>document.getElementById('again').onclick=function(){location.replace(this.dataset.url)}</script>
            </body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// What the page asks of the person in front of it: the camera or the microphone, its own
    /// `alert()`, `confirm()` and `prompt()`, and the file picker. Version 6 is the oldest layout that
    /// has all of them — the listener-based dialogs arrived in it, the media request in 5 — and every
    /// callback left `nil` is WebKit's own default for it.
    ///
    /// That default is why the dialogs are here at all: it dismisses an alert unseen, answers
    /// `confirm()` false and `prompt()` null, and never opens a picker. Measured before this was
    /// written, on a page that put its answers in its title: `confirm=false prompt=null`, with
    /// nothing on screen — a browser that quietly cannot upload a file, the thing the Mac's
    /// `PageDialogs` says it exists to prevent.
    private func installUIClient() {
        var client = WKPageUIClientV6()
        client.base.version = 6
        client.base.clientInfo = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        client.decidePolicyForUserMediaPermissionRequest = { _, _, origin, _, request, clientInfo in
            guard let clientInfo, let request else { return }
            // Handed to us by the UI process's main thread one line ago, which is the thread the
            // isolation below assumes; nothing is being smuggled across it.
            nonisolated(unsafe) let asked = request
            nonisolated(unsafe) let site = origin
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.handleMediaRequest(asked, origin: site) }
        }
        // The same thread argument as the media request, for each of these: WebKit calls them on the
        // UI process's main thread, and the listener is answered there too, later.
        client.runJavaScriptAlert = { _, text, _, origin, listener, clientInfo in
            guard let clientInfo, let listener else { return }
            nonisolated(unsafe) let asked = listener
            nonisolated(unsafe) let said = text
            nonisolated(unsafe) let site = origin
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                webView.presentDialog(.alert, message: said, origin: site, listener: asked) { _ in
                    WKPageRunJavaScriptAlertResultListenerCall(asked)
                }
            }
        }
        client.runJavaScriptConfirm = { _, text, _, origin, listener, clientInfo in
            guard let clientInfo, let listener else { return }
            nonisolated(unsafe) let asked = listener
            nonisolated(unsafe) let said = text
            nonisolated(unsafe) let site = origin
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                webView.presentDialog(.confirm, message: said, origin: site, listener: asked) { value in
                    WKPageRunJavaScriptConfirmResultListenerCall(asked, value != nil)
                }
            }
        }
        client.runJavaScriptPrompt = { _, text, defaultValue, _, origin, listener, clientInfo in
            guard let clientInfo, let listener else { return }
            nonisolated(unsafe) let asked = listener
            nonisolated(unsafe) let said = text
            nonisolated(unsafe) let offered = defaultValue
            nonisolated(unsafe) let site = origin
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                let kind = PageDialog.Kind.prompt(defaultText: StripWebView.string(from: offered))
                webView.presentDialog(kind, message: said, origin: site, listener: asked) { value in
                    // A nil string is what makes `prompt()` return null, which is what Cancel means.
                    let result = value.flatMap { typed in typed.withCString { WKStringCreateWithUTF8CString($0) } }
                    WKPageRunJavaScriptPromptResultListenerCall(asked, result)
                    if let result { WKRelease(UnsafeRawPointer(result)) }
                }
            }
        }
        client.runOpenPanel = { _, _, parameters, listener, clientInfo in
            guard let clientInfo, let listener else { return }
            nonisolated(unsafe) let asked = listener
            nonisolated(unsafe) let wanted = parameters
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.presentFileChoice(wanted, listener: asked) }
        }
        client.createNewPage = { _, configuration, action, _, clientInfo in
            guard let clientInfo, let configuration else { return nil }
            nonisolated(unsafe) let offered = configuration
            nonisolated(unsafe) let asked = action
            nonisolated(unsafe) var made: WKPageRef?
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            let gesture = action.map { WKNavigationActionHasUnconsumedUserGesture($0) } ?? false
            MainActor.assumeIsolated {
                let address = StripWebView.address(of: asked)
                // A `target=_blank` to somebody else's app is not a window: it is the same question a
                // click on it asks, and no column is made for it.
                if webView.handOff(address, gesture: gesture) { return }
                guard let created = webView.onCreatePage?(offered, address) else { return }
                // Handed back at +1: WebKit adopts the page it is given, which is why MiniBrowser's own
                // `createNewPage` on Windows ends in `WKRetainPtr(page).leakRef()`.
                WKRetain(UnsafeRawPointer(created.page))
                made = created.page
            }
            return made
        }
        client.close = { _, clientInfo in
            guard let clientInfo else { return }
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { webView.onClose?() }
        }
        client.mouseDidMoveOverElement = { _, hit, _, _, clientInfo in
            guard let clientInfo else { return }
            nonisolated(unsafe) let result = hit
            let webView = Unmanaged<StripWebView>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                webView.hoveredLink = StripWebView.link(in: result)
                // The scheme and nothing more: an address is where somebody was reading.
                if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" {
                    let over = webView.hoveredLink.flatMap { URL(string: $0)?.scheme } ?? "none"
                    FileHandle.standardError.write(Data("[six] hover: link=\(over)\n".utf8))
                }
            }
        }
        WKPageSetPageUIClient(page, &client.base)
    }

    /// The address a navigation action is for, `""` when it has none — `window.open()` with no
    /// argument, which is `about:blank` by the time anything loads.
    static func address(of action: WKNavigationActionRef?) -> String {
        guard let action, let request = WKNavigationActionCopyRequest(action) else { return "" }
        defer { WKRelease(UnsafeRawPointer(request)) }
        guard let url = WKURLRequestCopyURL(request) else { return "" }
        defer { WKRelease(UnsafeRawPointer(url)) }
        return takeString(WKURLCopyString(url))
    }

    private static func link(in result: WKHitTestResultRef?) -> String? {
        guard let result, let url = WKHitTestResultCopyAbsoluteLinkURL(result) else { return nil }
        defer { WKRelease(UnsafeRawPointer(url)) }
        let link = takeString(WKURLCopyString(url))
        return link.isEmpty ? nil : link
    }

    /// One of the three dialogs, handed up with an answer that can only be given once.
    ///
    /// The listener is retained here and released after `reply`, because the answer comes long after
    /// the callback has returned — after a person has read the message.
    private func presentDialog(_ kind: PageDialog.Kind, message: WKStringRef?, origin: WKSecurityOriginRef?,
                               listener: OpaquePointer, reply: @escaping (String?) -> Void) {
        WKRetain(UnsafeRawPointer(listener))
        let id = Foundation.UUID()
        var answered = false
        let answer: (String?) -> Void = { [weak self] value in
            guard !answered else { return }
            answered = true
            self?.owed[id] = nil
            reply(value)
            WKRelease(UnsafeRawPointer(listener))
        }
        owed[id] = { answer(nil) }
        guard let onDialog else { return answer(nil) }
        onDialog(PageDialog(host: Self.host(of: origin), message: Self.string(from: message), kind: kind, answer: answer))
    }

    /// The file picker's question, the same way: retained, answered once, cancelled with the view.
    private func presentFileChoice(_ parameters: WKOpenPanelParametersRef?, listener: WKOpenPanelResultListenerRef) {
        let multiple = parameters.map { WKOpenPanelParametersGetAllowsMultipleFiles($0) } ?? false
        let directories = parameters.map { WKOpenPanelParametersGetAllowsDirectories($0) } ?? false
        let extensions = (parameters.map { Self.strings(WKOpenPanelParametersCopyAcceptedFileExtensions($0)) } ?? [])
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        WKRetain(UnsafeRawPointer(listener))
        let id = Foundation.UUID()
        var answered = false
        let answer: ([URL]?) -> Void = { [weak self] urls in
            guard !answered else { return }
            answered = true
            self?.owed[id] = nil
            if let urls, !urls.isEmpty {
                // `file:///C:/…`: the form WebKit's own picker hands back, and the one it reads a
                // path out of again. The array adopts the URLs, so releasing it releases them.
                var items: [UnsafeRawPointer?] = urls.map { url in
                    url.absoluteString.withCString { WKURLCreateWithUTF8CString($0) }.map { UnsafeRawPointer($0) }
                }
                let array = items.withUnsafeMutableBufferPointer { WKArrayCreateAdoptingValues($0.baseAddress, $0.count) }
                // An empty array rather than nil for the MIME types: WebKit reads the argument as an
                // array without asking whether it is one.
                let noTypes = WKArrayCreate(nil, 0)
                WKOpenPanelResultListenerChooseFiles(listener, array, noTypes)
                if let array { WKRelease(UnsafeRawPointer(array)) }
                if let noTypes { WKRelease(UnsafeRawPointer(noTypes)) }
            } else {
                WKOpenPanelResultListenerCancel(listener)
            }
            WKRelease(UnsafeRawPointer(listener))
        }
        owed[id] = { answer(nil) }
        guard let onChooseFiles else { return answer(nil) }
        onChooseFiles(FileChoice(allowsMultiple: multiple, allowsDirectories: directories,
                                 extensions: extensions, answer: answer))
    }

    /// The host a dialog names as its speaker — the Mac's `PageDialogs.host(of:)`, and its fallback.
    private static func host(of origin: WKSecurityOriginRef?) -> String {
        let host = origin.map { takeString(WKSecurityOriginCopyHost($0)) } ?? ""
        return host.isEmpty ? "This page" : host
    }

    /// A `WKArray` of `WKString`s this side owns — a `Copy` call's result — read and released.
    private static func strings(_ array: WKArrayRef?) -> [String] {
        guard let array else { return [] }
        defer { WKRelease(UnsafeRawPointer(array)) }
        return (0..<WKArrayGetSize(array)).compactMap { index in
            WKArrayGetItemAtIndex(array, index).map { string(from: OpaquePointer($0)) }
        }
    }

    /// Classify the request and hand it up. Screen sharing is a third thing, and six has no word for
    /// it on any platform, so it is denied rather than asked about as if it were the camera.
    private func handleMediaRequest(_ request: WKUserMediaPermissionRequestRef, origin: WKSecurityOriginRef?) {
        let camera = WKUserMediaPermissionRequestRequiresCameraCapture(request)
        let microphone = WKUserMediaPermissionRequestRequiresMicrophoneCapture(request)
        let display = WKUserMediaPermissionRequestRequiresDisplayCapture(request)
        let denied = UserMediaPermissionRequestDenialReason(kWKPermissionDenied)
        guard !display, camera || microphone, let onMediaRequest, let site = Self.origin(of: origin) else {
            WKUserMediaPermissionRequestDeny(request, denied)
            return
        }
        // Which device to hand over is decided now, while the request still says what there is; the
        // first of each kind is what a browser with no device picker gives.
        let audio = microphone ? Self.firstDevice(WKUserMediaPermissionRequestAudioDeviceUIDs(request)) : ""
        let video = camera ? Self.firstDevice(WKUserMediaPermissionRequestVideoDeviceUIDs(request)) : ""
        // The answer arrives long after this returns — after a bar has been on screen — so the
        // request has to outlive the callback that delivered it.
        WKRetain(UnsafeRawPointer(request))
        var answered = false
        onMediaRequest(MediaRequest(origin: site, camera: camera, microphone: microphone) { allowed in
            guard !answered else { return }
            answered = true
            if allowed {
                let audioID = audio.withCString { WKStringCreateWithUTF8CString($0) }
                let videoID = video.withCString { WKStringCreateWithUTF8CString($0) }
                WKUserMediaPermissionRequestAllow(request, audioID, videoID)
                if let audioID { WKRelease(UnsafeRawPointer(audioID)) }
                if let videoID { WKRelease(UnsafeRawPointer(videoID)) }
            } else {
                WKUserMediaPermissionRequestDeny(request, denied)
            }
            WKRelease(UnsafeRawPointer(request))
        })
    }

    /// The origin as the Mac's `SitePermissions.string(for:)` writes it, so an answer given here and
    /// one given there are filed under the same string.
    private static func origin(of origin: WKSecurityOriginRef?) -> String? {
        guard let origin else { return nil }
        let scheme = takeString(WKSecurityOriginCopyProtocol(origin))
        guard !scheme.isEmpty else { return nil }
        let host = takeString(WKSecurityOriginCopyHost(origin))
        guard !host.isEmpty else { return "\(scheme)://" }
        let port = WKSecurityOriginGetPort(origin)
        return port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    private static func firstDevice(_ devices: WKArrayRef?) -> String {
        guard let devices else { return "" }
        defer { WKRelease(UnsafeRawPointer(devices)) }
        guard WKArrayGetSize(devices) > 0, let first = WKArrayGetItemAtIndex(devices, 0) else { return "" }
        return string(from: OpaquePointer(first))
    }

    /// `string(from:)` for a string this side owns — a `Copy` call's result — released once read.
    /// Not folded into `string(from:)` itself: `StripScript` reads strings WebKit still owns.
    static func takeString(_ ref: WKStringRef?) -> String {
        defer { if let ref { WKRelease(UnsafeRawPointer(ref)) } }
        return string(from: ref)
    }

    /// What the page says it is, asked rather than remembered.
    ///
    /// `didFinishNavigation` is not the moment a title exists: a page that sets `<title>` from a
    /// script, or simply late, finishes its navigation with the *previous* title still in place —
    /// which showed up here as a card still labelled DuckDuckGo with example.com in it. `StripWindow`
    /// polls these on a timer for that reason, the same "poll from Swift for anything that must
    /// wait" AGENTS.md settles on for page state.
    /// Both are `Copy` calls and are released once read: with every live column polled four times a
    /// second, the strings they hand back were otherwise a leak at the repaint rate.
    var title: String { Self.takeString(WKPageCopyTitle(page)) }

    var url: String {
        guard let activeURL = WKPageCopyActiveURL(page) else { return "" }
        defer { WKRelease(UnsafeRawPointer(activeURL)) }
        return Self.takeString(WKURLCopyString(activeURL))
    }

    /// `StripScript` reads a script's answer with this too, which is why it is not private.
    static func string(from ref: WKStringRef?) -> String {
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
    /// What the reload button does while the page is loading. The cancel it causes comes back as a
    /// failure that `handleFailedNavigation` knows is not one, so no error page follows it.
    func stopLoading() { WKPageStopLoading(page) }

    func setFrame(_ rect: RECT) {
        guard let hwnd else { return }
        if let placedFrame, placedFrame.left == rect.left, placedFrame.top == rect.top,
           placedFrame.right == rect.right, placedFrame.bottom == rect.bottom { return }
        placedFrame = rect
        MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, true)
    }

    func setVisible(_ visible: Bool) {
        guard let hwnd, isShown != visible else { return }
        isShown = visible
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
    }

    func destroy() {
        // Every question this page is still waiting on is answered Cancel first: its JavaScript is
        // suspended inside each of them, and the listeners are held until they are called.
        let pending = Array(owed.values)
        owed.removeAll()
        for cancel in pending { cancel() }
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
/// actor isolation. See `StripWebView.installScaleShim` for what it is rewriting and why.
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
        let width = Int32(Double(SixStripLoWord(lParam)) / scale)
        let height = Int32(Double(SixStripHiWord(lParam)) / scale)
        forwarded = SixStripPackWords(width, height)
    }
    return CallWindowProcW(original, hwnd, message, wParam, forwarded)
}
