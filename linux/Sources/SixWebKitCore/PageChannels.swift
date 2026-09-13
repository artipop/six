import CWebKitGTK
import Foundation

/// A user script and a message channel back from it, on every page as it is built.
///
/// The first two of the three things `SixCore`'s `WebMCPPage` says a front owes — the third, running
/// a function body, is `LivePage`. Generic rather than WebMCP's own, because this module cannot say
/// what to install: `SixWebKitCore` cannot import `SixCore` (`SixCore` reaches GRDB's SQLite, this
/// module ends up beside Adwaita's, and Clang refuses both in one compilation unit). So `SixBrowser`,
/// which has both halves, hands the script, the channel's name and where its messages go in at
/// launch — the way it hands `PermissionRequests` its handler — and this only wires them.
///
/// **Written on Windows and not yet built.** The WebKitGTK 6.0 calls are the documented ones; the
/// two things a build will say first are whether `WebKitUserContentManager` and `JSCValue` import as
/// `OpaquePointer` (final types with private structs in 6.0, so they should), and whether
/// `register_script_message_handler` takes its world as a third argument (6.0 folded
/// `…_in_world` into it). docs/webmcp.md keeps the list.
@MainActor
public enum PageChannels {
    public struct Channel {
        /// Injected at document start, top frame only, in the page's own world.
        public let source: String
        /// `window.webkit.messageHandlers.<name>` in that world.
        public let handlerName: String
        /// A message's column and its body, when the body is a string. Called on the main loop.
        public let receive: (UUID, String) -> Void

        public init(source: String, handlerName: String, receive: @escaping (UUID, String) -> Void) {
            self.source = source
            self.handlerName = handlerName
            self.receive = receive
        }
    }

    /// Set at launch, before the first page is built: a page is given what is here when it is made,
    /// and nothing added later reaches it. Empty installs nothing, which is the page as it always was.
    public static var channels: [Channel] = []

    /// Called from `WebView.container`, once per page and before its first load.
    public static func install(_ view: OpaquePointer, tabID: UUID) {
        guard !channels.isEmpty else { return }
        let webView = UnsafeMutableRawPointer(view).assumingMemoryBound(to: WebKitWebView.self)
        // Each view has a manager of its own unless one was handed in at construction, and none is.
        guard let manager = webkit_web_view_get_user_content_manager(webView) else { return }
        for channel in channels {
            if let script = webkit_user_script_new(
                channel.source,
                WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
                nil, nil
            ) {
                webkit_user_content_manager_add_script(manager, script)
                webkit_user_script_unref(script)
            }
            // Connected before the handler is registered, so the page's first message has somewhere
            // to go. The signal is detailed by the channel's name, which is how WebKitGTK tells one
            // handler's messages from another's.
            Signal.connect(
                UnsafeMutableRawPointer(manager),
                to: "script-message-received::" + channel.handlerName,
                unsafeBitCast(scriptMessageReceived, to: GCallback.self),
                holding: Signal.Box(Route(tabID: tabID, receive: channel.receive))
            )
            // `nil` world: the page's own, where the polyfill has to be for the page to reach it.
            _ = webkit_user_content_manager_register_script_message_handler(manager, channel.handlerName, nil)
        }
    }
}

/// What the signal's user data carries.
private final class Route {
    let tabID: UUID
    let receive: (UUID, String) -> Void

    init(tabID: UUID, receive: @escaping (UUID, String) -> Void) {
        self.tabID = tabID
        self.receive = receive
    }
}

/// `script-message-received` is `void (*)(WebKitUserContentManager*, JSCValue*, gpointer)` in 6.0 —
/// a `JSCValue` where 4.x passed a `WebKitJavascriptResult`. Written out, like every trampoline here
/// (`Signal` says why), because a handler entered through the wrong C signature finds its user data
/// in the wrong register.
private let scriptMessageReceived: @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
) -> Void = { _, value, data in
    guard let value, let data else { return }
    // Handed over by the main loop one line ago; the isolation assumed below is the same fact.
    nonisolated(unsafe) let message = value
    nonisolated(unsafe) let route = data
    MainActor.assumeIsolated {
        guard let route = Signal.Box.open(route, as: Route.self),
              jsc_value_is_string(message) != 0,
              let characters = jsc_value_to_string(message) else { return }
        let text = String(cString: characters)
        g_free(characters)
        route.receive(route.tabID, text)
    }
}
