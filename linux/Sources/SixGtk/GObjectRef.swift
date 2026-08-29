import CWebKitGTK
import Foundation

/// The one piece of real machinery a Swift GTK program needs, and the piece the plan priced as the
/// cost of not taking someone else's bindings: getting a Swift closure onto a GObject signal, and
/// getting it off again before the object dies.
///
/// The order in `deinit` is the whole point. A handler left connected past `g_object_unref` fires
/// into a Swift object that is no longer there, and it does not fail where you can see it — the
/// crash lands later, somewhere else, in C. So every handler is disconnected first, and only then is
/// the reference dropped. Every binding library that survives contact with GObject does this; ours
/// does it in one place.
open class GObjectRef {
    public let raw: UnsafeMutableRawPointer
    private var handlers: [CUnsignedLong] = []

    public init(_ raw: UnsafeMutableRawPointer) {
        self.raw = raw
        g_object_ref(raw)
    }

    /// A widget GTK handed us with a floating reference (everything from a `gtk_*_new`). `g_object_ref`
    /// sinks it, which is what we want: the wrapper owns a real reference for as long as it lives.
    /// Designated rather than convenience, so subclasses can call it.
    public init(_ widget: UnsafeMutablePointer<GtkWidget>) {
        self.raw = UnsafeMutableRawPointer(widget)
        g_object_ref(raw)
    }

    deinit {
        for id in handlers { g_signal_handler_disconnect(raw, id) }
        g_object_unref(raw)
    }

    // MARK: Signals

    /// The closure is boxed, handed to GLib as `user_data`, and released by the `GClosureNotify` that
    /// goes with it — so it lives exactly as long as the connection, whether the connection ends
    /// because we disconnected or because GLib tore the closure down.
    ///
    /// There is one method per *shape* of signal rather than a generic one: a `@convention(c)`
    /// function cannot be generic, so each trampoline is written out. Three shapes have covered
    /// everything so far.
    @discardableResult
    public func on(_ signal: String, _ body: @escaping @MainActor () -> Void) -> CUnsignedLong {
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data else { return }
            let box = Unmanaged<ClosureBox>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated {
                (box.body as? @MainActor () -> Void)?()
            }
        }
        return connect(signal, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(body))
    }

    /// A signal carrying one enum of its own — `load-changed` and its `WebKitLoadEvent`.
    @discardableResult
    public func onEvent(_ signal: String, _ body: @escaping @MainActor (UInt32) -> Void) -> CUnsignedLong {
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void = { _, event, data in
            guard let data else { return }
            let box = Unmanaged<ClosureBox>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated {
                (box.body as? @MainActor (UInt32) -> Void)?(event)
            }
        }
        return connect(signal, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(body))
    }

    /// `notify::…`, which hands over the property alongside the object. Neither is wanted — the point
    /// is that *something* changed and the value is read back from the object.
    @discardableResult
    public func onNotify(_ property: String, _ body: @escaping @MainActor () -> Void) -> CUnsignedLong {
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data else { return }
            let box = Unmanaged<ClosureBox>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated {
                (box.body as? @MainActor () -> Void)?()
            }
        }
        return connect("notify::" + property, unsafeBitCast(trampoline, to: GCallback.self), ClosureBox(body))
    }

    private func connect(_ signal: String, _ handler: GCallback, _ box: ClosureBox) -> CUnsignedLong {
        let pointer = Unmanaged.passRetained(box).toOpaque()
        // Not generic, and it cannot be: a `@convention(c)` function has no type parameters to
        // specialise, and asking for one crashes the compiler rather than diagnosing it (signal 6,
        // no source location). That is why the box erases its closure instead of carrying it in
        // its type.
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<ClosureBox>.fromOpaque(data).release()
        }
        let id = g_signal_connect_data(raw, signal, handler, pointer, release, GConnectFlags(rawValue: 0))
        handlers.append(id)
        return id
    }
}

/// A Swift closure with a stable address, so GLib can hold it as `gpointer`. The closure is stored
/// erased: what goes back to GLib is one `GClosureNotify` for every signal shape, and a C function
/// cannot be generic over the thing it releases.
///
/// `@unchecked Sendable` states the invariant the whole file rests on rather than dodging it: GTK is
/// a single-threaded toolkit driven from one main loop, every signal it emits arrives on that thread,
/// and the trampolines assert exactly that with `MainActor.assumeIsolated`. A box that reached
/// another thread would already be a bug several layers below this one.
final class ClosureBox: @unchecked Sendable {
    let body: Any
    init(_ body: Any) { self.body = body }
}

// MARK: - Casting

/// GTK's `GTK_WIDGET()` / `GTK_WINDOW()` family are C macros, so they do not reach Swift and every
/// downcast is written out by hand. Confining that to one function keeps it from spreading.
@inline(__always)
public func cast<T>(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T>? {
    pointer?.assumingMemoryBound(to: T.self)
}

@inline(__always)
public func cast<T>(_ pointer: UnsafeMutablePointer<some Any>?) -> UnsafeMutablePointer<T>? {
    UnsafeMutableRawPointer(pointer)?.assumingMemoryBound(to: T.self)
}

/// WebKitGTK's types are opaque in its headers, so Swift imports them as `OpaquePointer` rather than
/// as pointers to a struct. Same pointer, different spelling.
@inline(__always)
public func opaque(_ pointer: UnsafeMutableRawPointer?) -> OpaquePointer? {
    pointer.map(OpaquePointer.init)
}

@inline(__always)
public func opaque(_ pointer: UnsafeMutablePointer<some Any>?) -> OpaquePointer? {
    pointer.map(OpaquePointer.init)
}
