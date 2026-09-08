#if os(macOS)
import WebKit

/// What makes a video's own fullscreen button draw anything, and why it is two lines held for as
/// short a time as possible.
///
/// `.webViewElementFullscreenBehavior(.enabled)` is what lets a page ask for the screen at all, and
/// with it a `<video>` does go fullscreen: WebKit opens a `WebCoreFullScreenWindow`, moves the web
/// view into it, and `WebPage.fullscreenState` reaches `inFullscreen`. What it draws there is
/// nothing — a black screen over the whole display, with the sound still playing and the timer
/// still running. Leaving fullscreen gives the page back unharmed, which is what makes it look like
/// a lost page rather than a rendering bug, and it is a rendering bug.
///
/// It is not six's, and proving that was most of the work. Twenty-five lines — a `WebPage`, a
/// `WebView`, the modifier, nothing else — reproduce it exactly. The same URL in a `WKWebView`
/// behind an `NSViewRepresentable`, with `preferences.isElementFullscreenEnabled = true`, is
/// perfect. The difference between those two is how the view is *held*: SwiftUI's `WebView` hosts
/// it under Auto Layout (`translatesAutoresizingMaskIntoConstraints == false`, `autoresizingMask`
/// empty), and a `WKWebView` held that way has been going black in fullscreen since at least 2022 —
/// https://developer.apple.com/forums/thread/720612, where the answer is the same two lines as
/// here. WebKit's fullscreen controller moves the view into a window of its own and sizes it by
/// frame; a view that answers to constraints arrives there with none, so it is laid out at nothing
/// and the window shows its backdrop.
///
/// **So the flip is temporary, and that is the whole design.** Left on, it is a second regression
/// rather than a fix: SwiftUI goes on laying the rail out with constraints the view no longer
/// answers to, and the page flickers black under the pointer — hovering a video is enough, because
/// the media controls fading in is a layout pass. So the view answers to its frame only while
/// WebKit has it, from `enteringFullscreen` to the moment the state comes back to
/// `notInFullscreen`, and SwiftUI has it back the rest of the time.
///
/// Two things keep this honest. The door is the same `Mirror` one picture-in-picture uses, with the
/// same failure mode — if WebKit renames that storage nothing happens and fullscreen is black
/// again, which is where it was. And the watch is `withObservationTracking`, re-armed after every
/// change, because `fullscreenState` is the only notice WebKit gives.
extension WebPage {
    /// Starts following this page's fullscreen state. Called once, as the page is built.
    func watchElementFullscreenHosting() {
        withObservationTracking {
            _ = fullscreenState
        } onChange: { [weak self] in
            // `onChange` fires before the value moves, so the new state is read a hop later.
            Task { @MainActor in
                guard let self else { return }
                self.holdForElementFullscreen(self.fullscreenState != .notInFullscreen)
                self.watchElementFullscreenHosting()
            }
        }
    }

    /// Hands the web view its frame for the duration, and gives it back to Auto Layout after.
    private func holdForElementFullscreen(_ byFrame: Bool) {
        guard let view = backingWebView, view.translatesAutoresizingMaskIntoConstraints != byFrame else { return }
        view.translatesAutoresizingMaskIntoConstraints = byFrame
        view.autoresizingMask = byFrame ? [.width, .height] : []
    }
}
#endif
