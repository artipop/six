import CWebKitGTK
import Foundation

/// A site asking a page for a device, in the only vocabulary this module has.
///
/// It says nothing about *answers* — no origin type, no remembered decision, no profile. That is
/// deliberate and it is not modesty: `SixWebKitCore` cannot import `SixCore`, because `SixCore`
/// reaches GRDB's SQLite and this module ends up beside Adwaita's, and Clang refuses both in one
/// compilation unit. So the request is carried out flat and `SixBrowser` — which has both halves —
/// does the translating.
public struct PermissionAsk: Sendable {
    /// The column whose page asked, so the answer can be drawn where the question came from.
    public let tabID: UUID
    public let wantsCamera: Bool
    public let wantsMicrophone: Bool
    /// The page's own address.
    ///
    /// WebKitGTK's request carries no origin at all — where Apple hands the closure a
    /// `WKSecurityOrigin`, here there is only the view. For a request the page has just made those
    /// are the same site, which is why this is sound rather than a shortcut; and it is why
    /// `SitePermissions.origin(of:)` exists on the shared side already.
    public let pageURL: URL?
}

/// `permission-request`, wired by hand rather than through adwaita's signal machinery.
///
/// Not a preference. The signal is `gboolean (*)(WebKitWebView*, WebKitPermissionRequest*, gpointer)`
/// and adwaita's `HandlerType` has no case for it: `noArgsReturnsBool` returns the right thing but
/// takes no request, `oneArg` takes the request but returns nothing. Either mismatch is the same
/// class of bug as the `load-changed` crash — a handler entered through the wrong C signature — and
/// here the wrong half is the *return value*, which decides whether WebKitGTK considers the request
/// handled or falls back to its own denial. So this one is ours, with the signature written out.
@MainActor
public enum PermissionRequests {
    /// Asked whenever a page wants the camera or the microphone. Answer through the closure, now or
    /// after a bar has been up for a while — but always answer: the page's `getUserMedia()` promise
    /// is suspended until then.
    public static var handler: ((PermissionAsk, @escaping (Bool) -> Void) -> Void)?

    /// Connect a freshly built page. Called from `container`, once — `update` runs on every render,
    /// and this has no name-based deduplication of adwaita's kind.
    public static func connect(_ view: OpaquePointer, tabID: UUID) {
        let column = Unmanaged.passRetained(PermissionColumn(tabID: tabID)).toOpaque()
        g_signal_connect_data(
            UnsafeMutableRawPointer(view),
            "permission-request",
            unsafeBitCast(permissionRequested, to: GCallback.self),
            column,
            { data, _ in
                guard let data else { return }
                Unmanaged<PermissionColumn>.fromOpaque(data).release()
            },
            GConnectFlags(rawValue: 0)
        )
    }

    /// Classify the request and hand it up. Returns whether six took it: `FALSE` leaves it to
    /// WebKitGTK's own default handler, which denies — the right answer for a device six has no
    /// name for, and better than a silent grant.
    static func received(
        view: UnsafeMutableRawPointer,
        request: OpaquePointer,
        data: UnsafeMutableRawPointer
    ) -> gboolean {
        let column = Unmanaged<PermissionColumn>.fromOpaque(data).takeUnretainedValue()
        // `WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST` is a macro, and macros do not cross into Swift;
        // what it expands to is this.
        guard g_type_check_instance_is_a(
            UnsafeMutableRawPointer(request).assumingMemoryBound(to: GTypeInstance.self),
            webkit_user_media_permission_request_get_type()
        ) != 0 else { return 0 }

        let camera = webkit_user_media_permission_is_for_video_device(request) != 0
        let microphone = webkit_user_media_permission_is_for_audio_device(request) != 0
        // Screen sharing (`is_for_display_device`) is a third thing, and six has no word for it on
        // either platform. Falling through denies it rather than inventing an answer.
        guard camera || microphone, let handler else { return 0 }

        let uri = webkit_web_view_get_uri(view.assumingMemoryBound(to: WebKitWebView.self))
            .map { String(cString: $0) }
        let ask = PermissionAsk(
            tabID: column.tabID,
            wantsCamera: camera,
            wantsMicrophone: microphone,
            pageURL: uri.flatMap { URL(string: $0) }
        )
        // The answer arrives long after this returns — after a bar has been on screen — so the
        // request has to outlive the signal emission that delivered it.
        g_object_ref(UnsafeMutableRawPointer(request))
        handler(ask) { allowed in
            if allowed {
                webkit_permission_request_allow(request)
            } else {
                webkit_permission_request_deny(request)
            }
            g_object_unref(UnsafeMutableRawPointer(request))
        }
        return 1
    }
}

/// Which column a page belongs to, boxed for the trip through `user_data`. A class because that is
/// what `Unmanaged` retains, and `nonisolated` because the C handler that unboxes it is.
nonisolated final class PermissionColumn {
    let tabID: UUID
    init(tabID: UUID) { self.tabID = tabID }
}

/// The C entry point. A free constant rather than a method: `@convention(c)` cannot be formed from
/// anything that captures context, which is what an actor-isolated method does — the same reason
/// `Thumbnails` keeps its tracing free of the enum.
///
/// GTK emits its signals from the main loop and nowhere else, so the isolation being assumed here is
/// a fact about GTK rather than a hope.
private let permissionRequested: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?
) -> gboolean = { view, request, data in
    guard let view, let request, let data else { return 0 }
    // `nonisolated(unsafe)` because a raw pointer is not `Sendable` and these are about to cross
    // into main-actor code. Nothing is being smuggled: they were handed to us *by* the main loop
    // one line ago, and the isolation being assumed on the next line is the same fact.
    nonisolated(unsafe) let page = view
    nonisolated(unsafe) let ask = request
    nonisolated(unsafe) let column = data
    return MainActor.assumeIsolated {
        PermissionRequests.received(view: page, request: ask, data: column)
    }
}
