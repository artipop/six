import CWebKitGTK
import Foundation

/// Handing a Swift closure to a GObject signal, in one place.
///
/// Three call sites needed this — the page's `permission-request`, the strip's `scroll`, a column's
/// `pressed` — and each had grown its own box class, its own `GClosureNotify` and its own
/// `g_signal_connect_data`. That trio is exactly where a hand-written GObject bridge goes wrong: the
/// closure is freed while the signal is still connected, and the crash lands somewhere else. Written
/// once, it can be got right once.
///
/// What stays at the call site is the **trampoline**, and that is not laziness. Every signal has a
/// different C signature, and a `@convention(c)` function cannot be generic — an attempt at a
/// generic `GClosureNotify` took the compiler frontend down with SIGABRT and no diagnostic. So the
/// shape of each handler is written out where it is used, next to the signal it belongs to, which is
/// also where a reader wants to check it against the header.
public enum Signal {
    /// What GObject holds as `user_data`, retained until the closure is destroyed with it.
    ///
    /// Holds `Any` rather than taking a generic parameter, so that `connect`'s destroy notify below
    /// stays one concrete C function instead of one per closure type.
    public nonisolated final class Box {
        public let body: Any
        public init(_ body: Any) { self.body = body }

        /// The trampoline's side of the trip: `user_data` back to what the caller boxed.
        public static func open<Body>(_ data: UnsafeMutableRawPointer?, as type: Body.Type) -> Body? {
            guard let data else { return nil }
            return Unmanaged<Box>.fromOpaque(data).takeUnretainedValue().body as? Body
        }
    }

    /// Connect, and tie the box's lifetime to the connection.
    public static func connect(
        _ object: UnsafeMutableRawPointer?,
        to name: String,
        _ handler: GCallback,
        holding box: Box
    ) {
        g_signal_connect_data(
            object,
            name,
            handler,
            Unmanaged.passRetained(box).toOpaque(),
            { data, _ in
                guard let data else { return }
                Unmanaged<Box>.fromOpaque(data).release()
            },
            GConnectFlags(rawValue: 0)
        )
    }
}
