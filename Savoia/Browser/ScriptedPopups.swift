#if os(macOS)
import AppKit
import WebKit

/// `SAVOIA_POPUPS=1`: a window a page opens by script is the one WebKit asked for, so it has an opener.
/// A spike — the window is a bare `NSWindow` (docs/todo.md, Popups).
@MainActor
enum ScriptedPopups {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["SAVOIA_POPUPS"] != nil
    private static var windows: [NSWindow] = []
    private static var key = 0

    /// Stands in front of `WebPage`'s own UI delegate, which answers no `createWebView`.
    static func install(on webView: WKWebView) {
        guard isOn, !(webView.uiDelegate is Proxy) else { return }
        let proxy = Proxy(inner: webView.uiDelegate as? NSObject)
        // `uiDelegate` is weak.
        objc_setAssociatedObject(webView, &key, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.uiDelegate = proxy
    }

    fileprivate static func open(_ configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
        let size = NSSize(width: features.width?.doubleValue ?? 900, height: features.height?.doubleValue ?? 700)
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.orderFront(nil)
        windows.append(window)
        install(on: view)
        Log.info(.links, "popup opened with an opener, \(windows.count) so far")
        return view
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
            ScriptedPopups.open(configuration, features: windowFeatures)
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.window?.close()
        }
    }
}
#endif
