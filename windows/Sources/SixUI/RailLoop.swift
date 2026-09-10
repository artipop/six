import Dispatch
import Foundation
import SixBrowser
import WinSDK

/// The message loop, and the one line in it that makes Swift concurrency work here.
///
/// **`GetMessageW` in a `while` loop and `await` are mutually exclusive, and that is not a
/// preference.** On Windows the main actor's executor *is* libdispatch's main queue, and a thread
/// parked in `GetMessageW` never drains it: a `Task { @MainActor in … }` is enqueued and then simply
/// never runs. Measured with a standalone probe rather than inferred — the program went on as
/// though the task had never been written. docs/linux.md has been saying the same thing about
/// `g_main_loop_run` for as long as that front has existed, and the fix below is the one that front
/// wants too.
///
/// The fix is the same one CoreFoundation uses. libdispatch exports two entry points for exactly
/// this — a waitable handle that is signalled when the main queue has work, and a call that drains
/// it on the calling thread — and `CFRunLoop` on Linux and Windows is built on them. So the loop
/// waits on the message queue *and* that handle at once, and drains whichever woke it. Nothing is
/// polled, nothing is on a timer, and the window, its messages and the main actor are all on the
/// process's own main thread, which is what makes `MainActor.assumeIsolated` in the window
/// procedure true rather than merely unchecked.
///
/// The two symbols are underscored, and that is worth one sentence of justification: they are not
/// experimental, they are the supported seam for embedding the main queue in a foreign run loop —
/// swift-corelibs-foundation's own `CFRunLoop` is their oldest caller — and the alternative found
/// while looking for one (the `swift_task_enqueueMainExecutor_hook`) is not called at all any more
/// on this toolchain, because the main actor's executor is now implemented in Swift and enqueues
/// straight onto the queue.
@MainActor
public enum RailLoop {
    /// Signalled by libdispatch whenever the main queue has something to run. A `HANDLE` here, an
    /// eventfd on Linux; the same call names it on both.
    @_silgen_name("_dispatch_get_main_queue_handle_4CF")
    private static func mainQueueHandle() -> HANDLE?

    /// Runs everything the main queue has, on this thread, and returns. The argument is a Mach
    /// message on Darwin and unused everywhere else.
    @_silgen_name("_dispatch_main_queue_callback_4CF")
    private static func drainMainQueue(_ message: UnsafeMutableRawPointer?)

    /// Runs until `WM_QUIT`. The exit code is the one `PostQuitMessage` was given.
    public static func run(_ window: RailWindow) -> Int32 {
        var waitOn: [HANDLE?] = [mainQueueHandle()]
        var message = MSG()

        while true {
            // Before the wait, not only after it: work enqueued while the last batch of messages
            // was being dispatched is already there, and waiting for a *further* signal to notice it
            // would stall it until the next mouse move.
            drainMainQueue(nil)

            let woke = waitOn.withUnsafeMutableBufferPointer { buffer in
                MsgWaitForMultipleObjectsEx(1, buffer.baseAddress, INFINITE,
                                            DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
            }
            if woke == WAIT_FAILED {
                // Nothing to be done about it and nothing to be gained by spinning on it.
                FileHandle.standardError.write(Data("[six] message wait failed: \(GetLastError())\n".utf8))
                return 1
            }

            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if Int32(message.message) == WM_QUIT { return Int32(message.wParam) }
                // The rail's own keys and its ⌥-scroll, taken before the window they were aimed at —
                // usually WebKit's — ever sees them.
                if window.route(message) { continue }
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }
    }
}
