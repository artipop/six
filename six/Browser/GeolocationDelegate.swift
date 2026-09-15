#if os(macOS)
import WebKit

/// The one hook `WebPage` has no answer for. `WebPage.DeviceSensorAuthorization.Permission` has only
/// `.mediaCapture` and `.deviceOrientationAndMotion` — geolocation is a `WKUIDelegate` method
/// (`requestGeolocationPermissionFor:initiatedBy:`, macOS 27) with nothing upstream of it on
/// `WebPage`'s side at all (see [docs/permissions.md](../../docs/permissions.md)).
///
/// `WebPage` already installs its own `WKUIDelegateAdapter` on the real `WKWebView` underneath — the
/// same private object that answers `requestMediaCapturePermissionFor:` and the four JS dialogs, and
/// replacing it outright would take camera, microphone and every `alert()`/`confirm()` down with it.
/// Confirmed rather than assumed: a temporary log line on `WebViewResponder.claim` printed the live
/// delegate's class before this was written, and it is not `nil`.
///
/// So this does not replace it — it stands in front of it. `GeolocationDelegateProxy` answers
/// geolocation itself and forwards every other `WKUIDelegate` message to the adapter it displaced,
/// through `NSObject`'s own message-forwarding pair (`responds(to:)` / `forwardingTarget(for:)`) —
/// the standard Objective-C answer to "intercept one selector, pass the rest through unchanged."
/// `original` is `weak`, matching `WKWebView.UIDelegate`'s own attribute: `WebPage`'s internals are
/// what actually keep the adapter alive, not this proxy, and it is not this proxy's business to.
@available(macOS 27.0, *)
final class GeolocationDelegateProxy: NSObject, WKUIDelegate {
    private weak var original: WKUIDelegate?
    private let decide: (WKSecurityOrigin) async -> WKPermissionDecision

    init(original: WKUIDelegate?, decide: @escaping (WKSecurityOrigin) async -> WKPermissionDecision) {
        self.original = original
        self.decide = decide
    }

    /// The real wire selector — not `#selector(webView(_:requestGeolocationPermissionFor:initiatedBy:))`,
    /// which resolves to whatever Swift synthesizes for the `async` overload `WK_SWIFT_ASYNC_NAME`
    /// exposes and not to what WebKit's Objective-C runtime actually asks `respondsToSelector:`
    /// about. Measured, not assumed: with `#selector` here, `responds(to:)` answered `true` and
    /// WebKit still never called the method at all — the tell that the two selectors were never the
    /// same one. Built from the string instead, the way any selector `#selector` cannot reach is.
    private static let geolocationSelector = Selector(("webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:"))

    override func responds(to selector: Selector!) -> Bool {
        if selector == Self.geolocationSelector { return true }
        return original?.responds(to: selector) ?? super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        selector == Self.geolocationSelector ? nil : original
    }

    func webView(
        _ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        await decide(origin)
    }

    /// Installs itself on `webView`, once — a second call while one is already standing in front of
    /// this exact `webView` does nothing, since installing again would forward to the *proxy*
    /// instead of the adapter it was built to wrap the first time.
    @discardableResult
    static func install(on webView: WKWebView, decide: @escaping (WKSecurityOrigin) async -> WKPermissionDecision) -> GeolocationDelegateProxy? {
        if webView.uiDelegate is GeolocationDelegateProxy { return nil }
        let proxy = GeolocationDelegateProxy(original: webView.uiDelegate, decide: decide)
        webView.uiDelegate = proxy
        return proxy
    }
}
#endif
