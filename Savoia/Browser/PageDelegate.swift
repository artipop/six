#if os(macOS)
import AppKit
import WebKit

/// A tab's navigation and UI delegate: everything its page asks for that is not "load this here".
/// [links.md](../../docs/links.md) has the map.
final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Kind { case web, document, app }

    enum Event {
        case started, committed, finished
        case failedProvisional(any Error)
        /// A committed navigation failed, or the web content process ended.
        case ended
    }

    let kind: Kind
    weak var tab: BrowserTab?

    init(kind: Kind, tab: BrowserTab) {
        self.kind = kind
        self.tab = tab
    }

    // MARK: Where the page may go

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decide(action)
        // A cancelled navigation ends without a word to the delegate.
        if policy == .cancel, action.targetFrame?.isMainFrame != false { tab?.navigationCancelled() }
        return (policy, preferences)
    }

    private func decide(_ action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let tab, let url = action.request.url else { return .allow }
        switch kind {
        case .document:
            if url.scheme == "about" || url.scheme == "savoia" { return .allow }
            tab.onDocumentLink?(tab, url)
            return .cancel
        case .app:
            if url.scheme == MCPAppScheme.shell || url.scheme == MCPAppScheme.content || url.scheme == "about" {
                return .allow
            }
            tab.onDocumentLink?(tab, url)
            return .cancel
        case .web:
            break
        }
        let command = action.modifierFlags.contains(.command)
        LinkTrace.log("action \(url.absoluteString) target=\(action.targetFrame == nil ? "none" : "frame") type=\(action.navigationType.rawValue) button=\(action.buttonNumber) mods=\(action.modifierFlags.rawValue) cmd=\(command) download=\(action.shouldPerformDownload)")
        if action.shouldPerformDownload {
            tab.onDownload?(tab, action.request, nil)
            return .cancel
        }
        // Only a clicked link earns the system's "no application" sheet; a page sending itself to an
        // unclaimed scheme is probing, and is dropped.
        if ExternalScheme.isExternal(url) {
            guard action.navigationType == .linkActivated || ExternalScheme.hasHandler(for: url) else {
                LinkTrace.log("external \(url.scheme ?? "") unclaimed, not a click — dropped")
                return .cancel
            }
            let opened = ExternalScheme.open(url)
            LinkTrace.log("external \(url.absoluteString) opened=\(opened)")
            return .cancel
        }
        // `buttonNumber` is 1 for every click of the mouse, so ⌘ is the only signal there is.
        if action.navigationType == .linkActivated, command {
            tab.onLinkBehind?(tab, action.request)
            return .cancel
        }
        // No target frame is a window the page asks for; `createWebView` answers it with a tab.
        if action.targetFrame == nil { return .allow }
        // Before the load: an allowlisted site must never have the rules applied to it.
        if url.scheme?.hasPrefix("http") == true { tab.blocker?.note(tab.id, showing: url) }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard kind == .web, let tab, let url = response.response.url else { return .allow }
        let http = response.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let isAttachment = disposition.hasPrefix("attachment")
        guard !response.canShowMIMEType || isAttachment else { return .allow }
        LinkTrace.log("response \(url.absoluteString) canShow=\(response.canShowMIMEType) attachment=\(isAttachment)")
        tab.onDownload?(tab, URLRequest(url: url), response.response.suggestedFilename)
        return .cancel
    }

    func webView(_ webView: WKWebView,
                 respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard kind == .web, let certificates = CertificateStore.shared else { return (.performDefaultHandling, nil) }
        return await certificates.decide(challenge)
    }

    // MARK: Where it went

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.pageDid(.started, in: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.pageDid(.committed, in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.pageDid(.finished, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        tab?.pageDid(.failedProvisional(error), in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        tab?.pageDid(.ended, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.pageDid(.ended, in: webView)
    }

    // MARK: A window the page opens

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard kind == .web, let tab else { return nil }
        return tab.onPageWindow?(tab, configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, tab.isOpenedByPage else { return }
        tab.onPageClose?(tab)
    }

    // MARK: Dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard kind == .web, let tab else { return }
        _ = await ask(.alert, message, of: tab, from: frame, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard kind == .web, let tab else { return false }
        let answer = await ask(.confirm, message, of: tab, from: frame, in: webView)
        if case .accepted = answer { return true }
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard kind == .web, let tab else { return nil }
        let answer = await ask(.prompt, prompt, defaultText: defaultText, of: tab, from: frame, in: webView)
        if case .accepted(let text) = answer { return text ?? defaultText ?? "" }
        return nil
    }

    private func ask(_ kind: PageDialog.Kind, _ message: String, defaultText: String? = nil, of tab: BrowserTab,
                     from frame: WKFrameInfo, in webView: WKWebView) async -> PageDialog.Answer {
        if tab.isAutomated { tab.devTools?.automation.dialogOpened() }
        return await tab.dialogs.ask(kind, message: message, defaultText: defaultText, from: frame.securityOrigin,
                                     on: webView.window ?? PageDialogs.window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard kind == .web, let tab else { return nil }
        let answer = await tab.dialogs.ask(.files, panel: parameters, from: frame.securityOrigin,
                                           on: webView.window ?? PageDialogs.window)
        if case .files(let urls) = answer { return urls }
        return nil
    }

    // MARK: The camera and the microphone

    /// The page waits here while the bar is up; WebKit's own prompt can be neither remembered nor undone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard kind != .document, let tab, let permissions = tab.permissions else { return .deny }
        let allowed = await permissions.decide(SitePermissions.permissions(for: type),
                                               origin: SitePermissions.string(for: origin),
                                               in: tab.id, profileID: tab.profileID)
        return allowed ? .grant : .deny
    }

    // MARK: The position

    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        guard kind != .document, let tab, let permissions = tab.permissions else { return .deny }
        let allowed = await permissions.decide([.location], origin: SitePermissions.string(for: origin),
                                               in: tab.id, profileID: tab.profileID)
        return allowed ? .grant : .deny
    }

    // MARK: Notifications

    /// SPI. Unanswered, WebKit refuses and no question appears.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func webView(_ webView: WKWebView, notificationsFor origin: WKSecurityOrigin,
                 decisionHandler: @escaping (Bool) -> Void) {
        guard kind == .web, let tab, let permissions = tab.permissions else { return decisionHandler(false) }
        permissions.decide([.notifications], origin: SitePermissions.string(for: origin),
                           in: tab.id, profileID: tab.profileID, then: decisionHandler)
    }

    /// SPI: what `navigator.permissions.query` says. Unanswered, everything is `prompt`.
    @objc(_webView:queryPermission:forOrigin:completionHandler:)
    func webView(_ webView: WKWebView, queryPermission name: String, for origin: WKSecurityOrigin,
                 completionHandler: @escaping (WKPermissionDecision) -> Void) {
        let asked = SitePermission.allCases.first { SitePermissions.queryName(of: $0) == name }
        guard kind == .web, let tab, let asked,
              let allowed = tab.permissions?.decision(for: asked, origin: SitePermissions.string(for: origin),
                                                      profileID: tab.profileID) else {
            return completionHandler(.prompt)
        }
        completionHandler(allowed ? .grant : .deny)
    }

    // MARK: The window's frame

    /// SPI. Unanswered, a page reads `outerWidth` 0 and remote automation a window of no size.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, windowFrame completionHandler: @escaping (CGRect) -> Void) {
        // A tab behind another is in no window, and the window it will come back to is the one there is.
        completionHandler((webView.window ?? PageDialogs.window)?.frame ?? .zero)
    }

    // MARK: The context menu

    /// SPI, and the one place WebKit says what is under the pointer. Without it WebKit's own menu shows.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func webView(_ webView: WKWebView, contextMenuFrom proposed: NSMenu, for element: NSObject,
                 userInfo: Any?, completionHandler: @escaping (NSMenu?) -> Void) {
        guard let tab, let menu = tab.onContextMenu?(tab, Self.link(under: element)) else {
            return completionHandler(proposed)
        }
        // WebKit's own Inspect Element is the one item that knows the element under the pointer.
        if let inspect = proposed.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }) {
            proposed.removeItem(inspect)
            menu.addItem(.separator())
            menu.addItem(inspect)
        }
        completionHandler(menu)
    }

    private static func link(under element: NSObject) -> URL? {
        guard element.responds(to: Selector(("hitTestResult"))),
              let hit = element.value(forKey: "hitTestResult") as? NSObject,
              hit.responds(to: Selector(("absoluteLinkURL"))) else { return nil }
        return hit.value(forKey: "absoluteLinkURL") as? URL
    }
}

extension SitePermissions {
    /// The Permissions API's name for what Savoia keeps an answer about.
    static func queryName(of permission: SitePermission) -> String? {
        switch permission {
        case .camera: "camera"
        case .microphone: "microphone"
        case .location: "geolocation"
        case .notifications: "notifications"
        case .motion, .pageTools: nil
        }
    }

    /// A `PermissionStatus` a page holds hears `change` only if WebKit is told.
    static func tellPages(_ permission: SitePermission, changedFor origin: String) {
        guard let name = queryName(of: permission) else { return }
        let asked = WKStringCreateWithUTF8CString(name)
        let site = WKStringCreateWithUTF8CString(origin)
        WKPagePermissionChanged(asked, site)
        WKRelease(UnsafeRawPointer(asked))
        WKRelease(UnsafeRawPointer(site))
        if permission == .notifications { SiteNotifications.shared.policyChanged(for: origin) }
    }

    /// The origin as WebKit writes it, which reports 0 for a scheme's own port; agrees with `origin(of:)`.
    static func string(for origin: WKSecurityOrigin) -> String {
        let scheme = origin.`protocol`
        guard !scheme.isEmpty else { return "" }
        guard !origin.host.isEmpty else { return "\(scheme)://" }
        let base = "\(scheme)://\(origin.host)"
        return origin.port == 0 ? base : "\(base):\(origin.port)"
    }

    static func permissions(for type: WKMediaCaptureType) -> [SitePermission] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: []
        }
    }
}

/// `SAVOIA_LINKS_TRACE=1` narrates what the page asked for. Off, it costs the branch and nothing else.
enum LinkTrace {
    static let isOn = ProcessInfo.processInfo.environment["SAVOIA_LINKS_TRACE"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard isOn else { return }
        Log.debug(.links, message())
    }
}
#endif
