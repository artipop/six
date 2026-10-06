import WebKit

/// A window brought back by a relaunch — or rebuilt after a discard — does not start playing on its
/// own. The page asked for playback of a video nobody pressed play on this time; the answer is a
/// pause, until the first real click or key press in that frame.
///
/// Not `mediaTypesRequiringUserActionForPlayback`: a configuration is for the life of its view, and
/// that holds every later navigation too; this is one script, on one load.
/// It runs in Savoia's world: `play` is a DOM event and reaches every world, and the page can neither
/// see the listener nor take it down.
enum MediaHold {
    static let scriptName = "media-hold"

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
