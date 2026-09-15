#if os(macOS)
import ObjectiveC
import WebKit

/// Screen and window sharing — the one kind of capture `WebPage` says nothing about.
///
/// `getDisplayMedia()` itself needs none of this. With no delegate method to ask, WebKit presents
/// macOS's own content-sharing picker (`SCContentSharingPicker`, from its GPU process) and the page
/// gets what the person picked — measured before this file existed, with a `video:Screen` track
/// back in six as shipped. What `WebPage` does not publish is that it is *happening*: it has
/// `cameraCaptureState` and `microphoneCaptureState` and no third property, so the title bar's
/// indicator and the live-page budget's "don't discard a call" rule could not see a page sharing
/// the screen.
///
/// `WKWebView` has the state as SPI — `_displayCaptureState`, KVO-compliant (WebKit's
/// `PageClientImplCocoa::displayCaptureChanged` sends the will/did pair), and
/// `_setDisplayCaptureState:completionHandler:` to mute it. Both are guarded by `responds(to:)`, so
/// a macOS that drops them loses the indicator, not the browser.
enum DisplayCapture {
    private static let stateKey = "_displayCaptureState"
    private static let setter = Selector(("_setDisplayCaptureState:completionHandler:"))
    private static var observerKey: UInt8 = 0

    /// Starts reporting `webView`'s sharing state to `onChange`, once per web view.
    ///
    /// The observer is hung on the web view as an associated object rather than kept anywhere in six:
    /// it then lives exactly as long as the view it watches, which is the lifetime KVO wants from an
    /// observer, and a view that SwiftUI rebuilds gets a fresh one on its first claim.
    static func observe(_ webView: WKWebView, onChange: @escaping (WKMediaCaptureState) -> Void) {
        guard webView.responds(to: Selector((stateKey))),
              objc_getAssociatedObject(webView, &observerKey) == nil
        else { return }
        let observer = Observer(onChange: onChange)
        objc_setAssociatedObject(webView, &observerKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.addObserver(observer, forKeyPath: stateKey, options: [.initial, .new], context: nil)
    }

    /// Mutes or resumes sharing. `WKDisplayCaptureState` and `WKMediaCaptureState` are the same three
    /// values in the same order (none, active, muted), which is what lets one indicator drive both.
    static func setState(_ state: WKMediaCaptureState, on webView: WKWebView) {
        guard webView.responds(to: setter), let method = class_getInstanceMethod(type(of: webView), setter) else { return }
        typealias Setter = @convention(c) (WKWebView, Selector, Int, @convention(block) () -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, setter, state.rawValue, {})
    }

    private final class Observer: NSObject {
        let onChange: (WKMediaCaptureState) -> Void

        init(onChange: @escaping (WKMediaCaptureState) -> Void) {
            self.onChange = onChange
        }

        nonisolated override func observeValue(
            forKeyPath keyPath: String?, of object: Any?,
            change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
        ) {
            let raw = change?[.newKey] as? Int ?? 0
            MainActor.assumeIsolated {
                Log.debug(.pages, "screen sharing is \(["off", "on", "muted"][min(max(raw, 0), 2)])")
                onChange(WKMediaCaptureState(rawValue: raw) ?? .none)
            }
        }
    }
}
#endif
