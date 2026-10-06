#if os(macOS)
import AppKit
import WebKit

/// A window a page opens by script is the view WebKit asked for, so it has its opener and the two
/// can talk — what a sign-in or a payment popup is for. `WebPage` cannot be that view, so it is a
/// `WKWebView` in a window of its own and not a tab (docs/links.md). `SAVOIA_NO_POPUPS=1` goes back
/// to opening a tab with no opener.
@MainActor
enum ScriptedPopups {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["SAVOIA_NO_POPUPS"] == nil
    private static var popups: [PopupWindow] = []
    private static var key = 0

    /// Stands in front of `WebPage`'s own UI delegate, which answers no `createWebView`.
    static func install(on webView: WKWebView) {
        guard isOn, !(webView.uiDelegate is Proxy) else { return }
        let proxy = Proxy(inner: webView.uiDelegate as? NSObject)
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

    fileprivate static func open(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                                 from opener: WKWebView) -> WKWebView {
        let popup = PopupWindow(configuration: configuration, features: features, opener: opener.window)
        popups.append(popup)
        install(on: popup.view)
        Log.info(.links, "a page opened a window of its own, \(popups.count) open")
        return popup.view
    }

    fileprivate static func closed(_ popup: PopupWindow) {
        popups.removeAll { $0 === popup }
    }

    private final class Proxy: NSObject, WKUIDelegate {
        weak var inner: NSObject?

        init(inner: NSObject?) { self.inner = inner }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || inner?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            ScriptedPopups.open(configuration, features: windowFeatures, from: webView)
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.window?.close()
        }
    }
}

/// The window itself: the page's title, its host under it, and a lock while the address is https.
@MainActor
private final class PopupWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    let window: NSWindow
    let view: WKWebView
    private let lock = NSImageView()
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: NSWindow?) {
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
        ScriptedPopups.closed(self)
    }

    func webView(_ webView: WKWebView,
                 respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let certificates = CertificateStore.shared else { return (.performDefaultHandling, nil) }
        return await certificates.decide(challenge)
    }
}
#endif
