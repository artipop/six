import ObjectiveC
import WebKit

/// Picture-in-picture: the one thing a video can ask for that the new API has no switch for.
///
/// A `<video>` in a small window that floats above every other application is WebKit's feature, not
/// a browser's — the player, the window, the controls and the "return to the page" button are all
/// WebKit's, and the browser's whole job is to turn it on. Turning it on is the problem. The
/// preference is real and exists on macOS (`WKPreferencesSetAllowsPictureInPictureMediaPlayback` is
/// exported by the framework), but the only public way to reach it is
/// `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback`, which is declared for iOS alone, and
/// `WebPage.Configuration` has no field for it at all. Off is the default, and off is silent in
/// exactly the way element fullscreen was before `.webViewElementFullscreenBehavior(.enabled)`: no
/// button in WebKit's media controls, `video.webkitSupportsPresentationMode('picture-in-picture')`
/// false, and `video.requestPictureInPicture()` rejecting with `NotSupportedError — The video element
/// does not support the Picture-in-Picture mode`. Measured on a plain `<video>` through six's own MCP
/// server, the day after the fullscreen fix landed: `{"pip": false, "fs": true}`.
///
/// So the switch is SPI, on the terms this repository has already set for SPI
/// ([todo.md](../../docs/todo.md)): six is not sandboxed and not on the App Store, the only risk is a
/// selector going away in a macOS update, and the shape that takes is `responds(to:)` and a feature
/// that is quietly not there rather than a crash. Two things about how it is reached:
///
/// * **KVC, not `perform(_:with:)`.** `_setAllowsPictureInPictureMediaPlayback:` takes a `BOOL`, and
///   `perform(_:with:)` hands the method an object pointer where it reads one byte — the argument it
///   then sees is the low byte of an address, which is whatever the allocator felt like.
///   `setValue(_:forKey:)` looks for `set<Key>:` and then `_set<Key>:`, and boxes the number
///   properly. With `perform` the preference read back false and stayed false.
/// * **The `WKWebView` behind the page is found with `Mirror`.** `WebPage` does not hand it out; it
///   is a `lazy` stored property and the label is the compiler's own. A page nobody has asked
///   anything of has none yet, which is what the `_ = url` is for — reading any property builds it.
///   If WebKit renames that storage, `allowPictureInPicture` does nothing and six is back where it
///   was before this file.
///
/// **Everything else is the page's own API**, run in six's content world, and that is a measurement
/// rather than a preference. macOS `WKWebView` also carries `_canTogglePictureInPicture`,
/// `_togglePictureInPicture` and `_isPictureInPictureActive` — what Safari's own Video menu is —
/// and all three answer for the video WebKit has designated the page's *main* one for the playback
/// controls manager. That designation is not the same question as "is this video in the floating
/// window": with a plain `<video>` demonstrably in picture-in-picture (`webkitPresentationMode` is
/// `'picture-in-picture'`, `document.pictureInPictureElement` set) `_isPictureInPictureActive` was
/// false and `_canTogglePictureInPicture` was false, and the page was duly discarded by the live-page
/// budget with the player still on screen. So the SPI is asked *as well*, because it sees frames a
/// script in the main frame cannot, but it is never the only answer.
///
/// **The floating window is nobody's here.** `PIPViewController` and its `PIPPanel` are six's, but the
/// player on the screen is drawn by `PIPAgent` — a process of its own, on a system layer above every
/// ordinary window — and six's panel never appears in the on-screen window list at all. So the two
/// things a person asks for first, that it travel with the browser window on ⌘Tab and that it sit
/// under the top bar instead of in the corner of the screen, cannot be done from here. Both were
/// tried: `addChildWindow` moves six's invisible panel, changes nothing on screen, and leaves the
/// player visible after WebKit has ordered it out; `_pipSetWindowContentRect:` is how the agent tells
/// six where the player went, not the other way round.
/// [layout.md](../../docs/layout.md#picture-in-picture) has the measurements.
extension WebPage {
    /// Lets this page's videos into picture-in-picture. Called once, as the page is built.
    ///
    /// It wants a page that exists: the preference travels to the web content process when it
    /// changes, and a page with no web view yet has nothing to travel to.
    func allowPictureInPicture() {
        guard let preferences = backingWebView?.configuration.preferences,
              preferences.responds(to: Self.allowsPictureInPicture) else { return }
        preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
    }

    /// Is any of this page's videos in the floating window right now?
    ///
    /// Two answers, because neither one is complete. The page's own is exact for every video in the
    /// main frame and blind to cross-origin iframes — an embedded player on somebody else's page.
    /// WebKit's is the other way round: it sees whatever frame the video is in and only if that video
    /// is the one it considers the page's main one.
    var isInPictureInPicture: Bool {
        get async {
            if webKitReportsPictureInPicture { return true }
            let answer = try? await six("""
                return Array.prototype.some.call(document.querySelectorAll('video'), function (video) {
                    return video.webkitPresentationMode === 'picture-in-picture';
                });
                """)
            return (answer as? Bool) ?? false
        }
    }

    /// In, or back out — the same command both ways, which is how a person thinks of the button.
    ///
    /// Which video, on a page with several, is the question the command is really about, and the
    /// answer is the one being watched: a video already floating comes back first, otherwise a
    /// playing video beats a paused one and the bigger picture wins between equals. WebKit's own
    /// answer to this (`_togglePictureInPicture`) is better informed and does nothing at all for a
    /// video it has not designated as the page's main one, which is most of them.
    ///
    /// Nothing is reported back. A page with no video to float does nothing, on purpose: there is no
    /// bar in six that would be right for saying "this page has no video", and a menu item that has
    /// to explain itself when pressed in the wrong place is a menu item nobody presses twice.
    func togglePictureInPicture() async {
        _ = try? await six("""
            var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
            var floating = videos.filter(function (video) {
                return video.webkitPresentationMode === 'picture-in-picture';
            })[0];
            if (floating) {
                floating.webkitSetPresentationMode('inline');
                return 'inline';
            }
            var candidates = videos.filter(function (video) {
                if (video.videoWidth < 1 || video.disablePictureInPicture) { return false; }
                return !video.webkitSupportsPresentationMode
                    || video.webkitSupportsPresentationMode('picture-in-picture');
            });
            candidates.sort(function (a, b) {
                if (a.paused !== b.paused) { return a.paused ? 1 : -1; }
                return b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight;
            });
            if (!candidates.length) { return 'none'; }
            candidates[0].webkitSetPresentationMode('picture-in-picture');
            return 'picture-in-picture';
            """)
    }

    // MARK: The private door

    /// WebKit's own answer, for the video it considers this page's main one. Read the note above
    /// before trusting it on its own: it is false for plenty of videos that are floating.
    private var webKitReportsPictureInPicture: Bool {
        guard let view = backingWebView, view.responds(to: Self.isActive) else { return false }
        return view.value(forKey: "isPictureInPictureActive") as? Bool ?? false
    }

    /// The web view behind the page. Reading `url` first is not a nicety: the storage is lazy, and a
    /// page that has been built but never asked anything has nothing in it.
    ///
    /// Not private, because the same door is the only way to reach the hosting bug that element
    /// fullscreen dies of (`PageElementFullscreen`).
    var backingWebView: WKWebView? {
        _ = url
        for child in Mirror(reflecting: self).children where child.label == Self.backingWebViewLabel {
            return Mirror(reflecting: child.value).children.first?.value as? WKWebView
        }
        return nil
    }

    private static let backingWebViewLabel = "$__lazy_storage_$_backingWebView"
    private static let allowsPictureInPicture = Selector(("_setAllowsPictureInPictureMediaPlayback:"))
    private static let isActive = Selector(("_isPictureInPictureActive"))
}
