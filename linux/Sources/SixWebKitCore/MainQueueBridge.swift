import CWebKitGTK
import Foundation
import Glibc

/// The one line that makes Swift concurrency run on this front.
///
/// **`g_main_loop_run` and `await` are mutually exclusive until this is installed**, and
/// docs/linux.md has said the first half of that for as long as the front has existed: *"A `Task`
/// never runs. Under `g_main_loop_run` the thread belongs to GLib, and nothing drains Swift's
/// main-actor executor."* That executor is libdispatch's main queue, and a thread inside GLib's
/// loop never drains it — a `Task { @MainActor in … }` is enqueued and then simply never runs. The
/// same thing was true on the Windows front and was measured there, with a standalone probe, before
/// either front was believed.
///
/// The fix is not a rewrite of how the app runs. libdispatch has exported the seam for embedding
/// its main queue in a foreign run loop for as long as CoreFoundation has needed one:
/// `_dispatch_get_main_queue_handle_4CF` hands back a descriptor that becomes readable when the
/// main queue has work, and `_dispatch_main_queue_callback_4CF` drains the queue on the calling
/// thread. swift-corelibs-foundation's own `CFRunLoop` is built on the pair on this platform.
/// So GLib is asked to watch that descriptor, and everything Swift has queued runs on GTK's own
/// thread, in GTK's own loop, between one event and the next.
///
/// The two symbols are underscored, and that is worth a sentence rather than a shrug: they are not
/// experimental, they are the supported way in, and the properly-spelled alternative — SE-0463's
/// `ExecutorFactory` — does not exist in the toolchain this front is built with.
@MainActor
public enum MainQueueBridge {
    private static var installed = false
    private static var handle: Int32 = -1

    /// Call once, after GTK is up. Safe to call again; it does nothing the second time.
    ///
    /// After GTK is up and not before: the descriptor is created on first use and the watch has to
    /// go on the main context the app is actually going to run.
    public static func install() {
        guard !installed else { return }
        installed = true
        handle = sixDispatchMainQueueHandle()
        guard handle >= 0 else {
            FileHandle.standardError.write(Data("[six] no main-queue handle; await will not run\n".utf8))
            return
        }
        // `G_IO_IN` alone: there is nothing to write and an error on an eventfd this process owns
        // is not a thing that happens. Returning `G_SOURCE_CONTINUE` keeps the watch for the life of
        // the process, which is what is wanted — this is not a one-shot.
        // The descriptor is read back out of the callback's own argument rather than captured: a
        // `@convention(c)` closure has no context to capture into, which is the same constraint
        // every trampoline in this module is written around.
        g_unix_fd_add(handle, G_IO_IN, { descriptor, _, _ in
            sixDrainMainQueue(nil)
            // An eventfd stays readable until it is read, so a watch that only drained the queue
            // would be called again immediately and forever. libdispatch opened it `EFD_NONBLOCK`,
            // so this cannot block even when there is nothing there to read.
            var counter: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &counter) { buffer in
                read(descriptor, buffer.baseAddress, buffer.count)
            }
            return 1                                  // G_SOURCE_CONTINUE
        }, nil)
    }
}

/// Signalled by libdispatch whenever the main queue has something to run — an eventfd here, a
/// `HANDLE` on Windows, a Mach port on Darwin. The same call names it on all three.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private nonisolated func sixDispatchMainQueueHandle() -> Int32

/// Runs everything the main queue has, on this thread, and returns. The argument is a Mach message
/// on Darwin and unused everywhere else.
@_silgen_name("_dispatch_main_queue_callback_4CF")
private nonisolated func sixDrainMainQueue(_ message: UnsafeMutableRawPointer?)
