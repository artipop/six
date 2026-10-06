#if os(macOS)
import AppKit
import WebKit

/// A window a page opens by script is the view WebKit asked for, so it has its opener and the two
/// can talk — what a sign-in or a payment popup is for. `WebPage` cannot be that view, so it is a
/// `WKWebView` in a window of its own and not a tab (docs/links.md). A page that asked for nothing
/// about the window and named an address meant a tab, and gets one, with no opener.
/// `SAVOIA_NO_POPUPS=1` makes every one a tab, `SAVOIA_ALL_POPUPS=1` every one a window.
@MainActor
enum ScriptedPopups {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["SAVOIA_NO_POPUPS"] == nil
    private static let isAlways = ProcessInfo.processInfo.environment["SAVOIA_ALL_POPUPS"] != nil
    /// What a tab answers a page with, and the window answers with too.
    static var permissions: SitePermissions?
    static var downloads: DownloadStore?
    /// Opens the address as a tab beside the one that asked; false when that tab is gone.
    static var openTab: ((UUID, URL) -> Bool)?
    private static var popups: [PopupWindow] = []
    private static var key = 0

    /// Stands in front of `WebPage`'s own UI delegate, which answers no `createWebView`.
    static func install(on webView: WKWebView, tabID: UUID, profileID: UUID?) {
        guard isOn, !(webView.uiDelegate is Proxy) else { return }
        let proxy = Proxy(inner: webView.uiDelegate as? NSObject, tabID: tabID, profileID: profileID)
        // `uiDelegate` is weak.
        objc_setAssociatedObject(webView, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.uiDelegate = proxy
    }

    /// ⌘W belongs to the popup while it is the key window.
    static func closeKeyWindow() -> Bool {
        guard let popup = popups.first(where: { $0.window.isKeyWindow }) else { return false }
        popup.window.close()
        return true
    }

    static var views: [WKWebView] { popups.map(\.view) }

    /// Between tests: a window one test left open is not the next one's.
    static func closeAll() {
        for popup in popups { popup.window.close() }
    }

    /// A test's hand on the sheets these windows put up; says how many it answered.
    static func answerSheets(accepting: Bool) -> Int {
        let sheets = popups.compactMap { popup in popup.window.attachedSheet.map { (popup.window, $0) } }
        for (window, sheet) in sheets {
            window.endSheet(sheet, returnCode: accepting ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }
        return sheets.count
    }

    fileprivate static func open(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                                 for url: URL?, from opener: WKWebView, tabID: UUID, profileID: UUID?) -> WKWebView? {
        let asked = [features.width, features.height, features.x, features.y, features.menuBarVisibility,
                     features.statusBarVisibility, features.toolbarsVisibility, features.allowsResizing]
        // An address that comes later can only reach the view WebKit was handed.
        if !isAlways, asked.allSatisfy({ $0 == nil }), let url, url.scheme?.hasPrefix("http") == true,
           openTab?(tabID, url) == true {
            Log.info(.links, "a page opened \(url.host() ?? "") asking nothing of the window: a tab")
            return nil
        }
        let popup = PopupWindow(configuration: configuration, features: features, opener: opener.window,
                                profileID: profileID)
        popups.append(popup)
        // `uiDelegate` is weak, and so is the proxy's hold on the window: `popups` keeps it.
        let proxy = Proxy(inner: popup, tabID: tabID, profileID: profileID)
        objc_setAssociatedObject(popup.view, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        popup.view.uiDelegate = proxy
        let said = asked.map { $0.map { "\($0)" } ?? "-" }
        Log.info(.links, "a page opened a window for \(url?.host() ?? "nothing yet"), asked for \(said[0])x\(said[1]), menu \(said[4]) status \(said[5]) toolbars \(said[6]) resizing \(said[7]), \(popups.count) open")
        return popup.view
    }

    fileprivate static func closed(_ popup: PopupWindow) {
        popups.removeAll { $0 === popup }
    }

    private final class Proxy: NSObject, WKUIDelegate {
        weak var inner: NSObject?
        let tabID: UUID
        let profileID: UUID?

        init(inner: NSObject?, tabID: UUID, profileID: UUID?) {
            self.inner = inner
            self.tabID = tabID
            self.profileID = profileID
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || inner?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            ScriptedPopups.open(configuration, features: windowFeatures, for: navigationAction.request.url,
                                from: webView, tabID: tabID, profileID: profileID)
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.window?.close()
        }
    }
}

/// The window itself: the page's title, its host under it, and a lock while the address is https.
/// It answers the page's dialogs, the camera and the microphone, and a file, as a tab does.
@MainActor
private final class PopupWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: NSWindow
    let view: WKWebView
    /// What `SitePermissions` queues this window's questions under.
    private let id = UUID()
    private let profileID: UUID?
    private var isAsking = false
    private var hasCommitted = false
    private let lock = NSImageView()
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: NSWindow?, profileID: UUID?) {
        self.profileID = profileID
        let screen = (opener?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // What the page asked for, kept on the screen; a third of it by a half when it asked for nothing.
        let width = min(max(features.width?.doubleValue ?? screen.width / 3, 320), screen.width)
        let height = min(max(features.height?.doubleValue ?? screen.height / 2, 240), screen.height)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        view.navigationDelegate = self

        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        lock.contentTintColor = .secondaryLabelColor
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = lock
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        observations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.describe() }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.describe() }
            },
        ]
        if let opener {
            let frame = opener.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func describe() {
        let host = view.url?.host() ?? ""
        let title = view.title ?? ""
        window.title = title.isEmpty ? host : title
        // The scheme is spelled out when it is not https: that is the address a person should read twice.
        let isSecure = view.url?.scheme == "https"
        window.subtitle = isSecure || host.isEmpty ? host : (view.url?.scheme ?? "") + "://" + host
        lock.isHidden = !isSecure
    }

    func windowWillClose(_ notification: Notification) {
        observations = []
        view.stopLoading()
        ScriptedPopups.permissions?.forget(id)
        ScriptedPopups.closed(self)
    }

    // MARK: Dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await PageDialogs.alert(message, from: frame.securityOrigin, on: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await PageDialogs.confirm(message, from: frame.securityOrigin, on: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await PageDialogs.prompt(prompt, defaultText: defaultText, from: frame.securityOrigin, on: window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await PageDialogs.files(parameters, from: frame.securityOrigin, on: window)
    }

    // MARK: Camera and microphone

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        await decide(.mediaCapture(type), origin: origin)
    }

    private func decide(_ permission: WebPage.DeviceSensorAuthorization.Permission,
                        origin: WKSecurityOrigin) async -> WKPermissionDecision {
        guard let permissions = ScriptedPopups.permissions, let profileID else { return .deny }
        let allowed = await withCheckedContinuation { continuation in
            permissions.decide(SitePermissions.permissions(for: permission),
                               origin: SitePermissions.string(for: origin), in: id, profileID: profileID) {
                continuation.resume(returning: $0)
            }
            ask()
        }
        return allowed ? .grant : .deny
    }

    /// The tab's bar, as a sheet: this window holds one page, so there is nobody else to stop.
    private func ask() {
        guard !isAsking, let permissions = ScriptedPopups.permissions,
              let question = permissions.question(for: id) else { return }
        isAsking = true
        let devices = ListFormatter.localizedString(byJoining: question.permissions.map(\.label))
        let alert = NSAlert()
        alert.messageText = String(localized: "\(question.host) wants to use your \(devices).")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Block"))
        let id = id
        alert.beginSheetModal(for: window) { [weak self] response in
            permissions.answer(response == .alertFirstButtonReturn, for: id)
            self?.isAsking = false
            self?.ask()
        }
    }

    // MARK: Files

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommitted = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.shouldPerformDownload else { return .allow }
        download(action.request, suggestedName: nil)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard response.isForMainFrame, let url = response.response.url else { return .allow }
        let http = response.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        guard !response.canShowMIMEType || disposition.hasPrefix("attachment") else { return .allow }
        download(URLRequest(url: url), suggestedName: response.response.suggestedFilename)
        return .cancel
    }

    private func download(_ request: URLRequest, suggestedName: String?) {
        ScriptedPopups.downloads?.start(request, suggestedName: suggestedName, referrer: view.url,
                                        profileID: profileID, cookies: view.configuration.websiteDataStore)
        // Opened only to carry the file: there is no page to show.
        if !hasCommitted { window.close() }
    }

    func webView(_ webView: WKWebView,
                 respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let certificates = CertificateStore.shared else { return (.performDefaultHandling, nil) }
        return await certificates.decide(challenge)
    }
}
#endif
