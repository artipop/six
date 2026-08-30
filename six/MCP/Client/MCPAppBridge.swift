import Foundation
import WebKit

/// The relay between the app's frame and six.
///
/// It runs in the **shell**, six's own document, and only there (`forMainFrameOnly: true`): the
/// app's frame is never injected into. A user script is not subject to the document's CSP, which is
/// why the shell can be served under `default-src 'none'` and still have a relay.
///
/// The whole of it is four moves — forward what the frame says, hand back what six answers, and
/// tell six how big the column is, twice: once on load and again whenever it changes.
nonisolated enum MCPAppBridge {
    static let frameID = "six-mcp-view"
    static let handlerName = "sixMcpApp"

    static let source = """
    (function () {
      var pending = [];
      function view() {
        var frame = document.getElementById("\(frameID)");
        return frame && frame.contentWindow;
      }
      function send(payload) {
        try { webkit.messageHandlers.\(handlerName).postMessage(JSON.stringify(payload)); } catch (error) {}
      }
      function flush() {
        var target = view();
        if (!target) return;
        while (pending.length) target.postMessage(pending.shift(), "*");
      }
      function viewport() {
        send({ sixViewport: { width: window.innerWidth, height: window.innerHeight } });
      }
      window.addEventListener("message", function (event) {
        var target = view();
        if (!target || event.source !== target) return;
        send({ sixMessage: event.data });
        flush();
      });
      window.addEventListener("resize", viewport);
      window.addEventListener("DOMContentLoaded", viewport);
      window.addEventListener("load", function () { viewport(); flush(); });
      window.__sixMcpApp = {
        deliver: function (text) { pending.push(JSON.parse(text)); flush(); }
      };
    })();
    """

    /// Delivers one JSON-RPC message to the app. A function body, no `await` — see `PageScripts`.
    static let deliverBody = "window.__sixMcpApp.deliver(text);"
}

/// One per running app: the shell's messages come in here and go to the session on the main actor.
nonisolated final class MCPAppMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: MCPAppSession?

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the shell talks to six. The app's own frame shares this content controller — every
        // frame of a page does — so the frame is checked rather than trusted.
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        Task { @MainActor [weak session] in
            session?.receive(text)
        }
    }
}
