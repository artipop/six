import WebKit

/// A window brought back by a relaunch — or rebuilt after a discard — does not start playing on its
/// own: until the first click or key press in it, the page's `play()` is refused as Safari refuses autoplay.
///
/// Not `mediaTypesRequiringUserActionForPlayback`: a configuration is for the life of its view, and
/// that holds every later navigation too. The preference behind it can be changed while the view lives. SPI;
/// without it a user script pauses what starts, in Savoia's world, where the page can neither see nor remove it.
enum MediaHold {
    static let scriptName = "media-hold"

    static var isPreference: Bool {
        WKPreferences.instancesRespond(to: #selector(GesturePreferences.requireGestureForAudio(_:)))
            && WKPreferences.instancesRespond(to: #selector(GesturePreferences.requireGestureForVideo(_:)))
    }

    static func set(_ held: Bool, in view: WKWebView) {
        guard isPreference else { return }
        let preferences = unsafeBitCast(view.configuration.preferences, to: GesturePreferences.self)
        preferences.requireGestureForAudio(held)
        preferences.requireGestureForVideo(held)
    }

    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .savoia)
    }

    private static let source = """
    (() => {
      let touched = false;
      const touch = event => { if (event.isTrusted) touched = true; };
      for (const type of ['pointerdown', 'keydown', 'touchstart'])
        addEventListener(type, touch, { capture: true, passive: true });
      // Media events do not bubble, so this listens on the way down.
      addEventListener('play', event => {
        if (!touched && event.target instanceof HTMLMediaElement) event.target.pause();
      }, true);
    })();
    """
}

@objc private protocol GesturePreferences {
    @objc(_setRequiresUserGestureForAudioPlayback:) func requireGestureForAudio(_ required: Bool)
    @objc(_setRequiresUserGestureForVideoPlayback:) func requireGestureForVideo(_ required: Bool)
}
