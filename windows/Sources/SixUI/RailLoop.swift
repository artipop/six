import Dispatch
import Foundation
import SixBrowser
import WinSDK

/// The message loop, rearranged so that Swift concurrency runs at all.
///
/// **This is not a preference. `GetMessageW` in a `while` loop and `await` are mutually exclusive.**
/// On Windows, the main actor's executor is libdispatch's main queue, and a thread parked in
/// `GetMessageW` never drains it: an `await` that hops back to the main actor is enqueued and then
/// simply never runs. Measured, not assumed — a `Task { @MainActor in … }` under the old loop landed
/// nowhere and the program went on as though it had never been written. docs/linux.md has been
/// saying the same thing about `g_main_loop_run` for as long as that front has existed.
///
/// The rearrangement is the smallest one that works. `dispatchMain()` gives the process to
/// libdispatch, which drains the main queue — on Windows, on a worker thread of its own rather than
/// on the process's first thread. So the window is *created* there too, inside the first block this
/// posts: Win32 ties a window to the thread that created it and does not care which thread that is,
/// and the one thing that must be true is that the window, its message loop and the main actor are
/// all the same thread. They are, and `MainActor.assumeIsolated` in the window procedure is
/// therefore telling the truth — it is called from inside a main-queue block, which is exactly what
/// that assertion checks.
///
/// What is lost is the blocking wait: the loop cannot sit in `GetMessageW`, because that is the
/// thread the rest of Swift needs back. `MsgWaitForMultipleObjectsEx` is the compromise — it blocks
/// like `GetMessageW` and returns the instant input arrives, but it gives up after four
/// milliseconds so that whatever the main actor has queued gets its turn. Input latency is
/// unchanged (the wait wakes on the message, not on the timeout); a main-actor continuation waits at
/// most one slice, and an idle window costs two hundred and fifty empty wake-ups a second, which is
/// less than the page in it costs while doing nothing.
@MainActor
public enum RailLoop {
    /// How long the loop is allowed to sit in the wait before handing the thread back to Swift.
    private static let slice: DWORD = 4

    private static var window: RailWindow?

    /// Give the process to Swift, and start the window on the thread Swift will be running on.
    ///
    /// `startUp` runs once, on the main queue, and everything it creates belongs to that thread.
    /// Never returns: `dispatchMain()` parks the calling thread for the life of the process, and
    /// the way out is `WM_QUIT`, below.
    public nonisolated static func run(_ startUp: @escaping @MainActor () -> RailWindow?) -> Never {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let created = startUp() else {
                    FileHandle.standardError.write(Data("[six] the rail window could not be created\n".utf8))
                    exit(1)
                }
                window = created
                pump()
            }
        }
        dispatchMain()
    }

    /// One slice: everything Windows has to say, then back to the queue.
    ///
    /// It re-posts itself rather than looping, and that is the whole trick — between two slices the
    /// main queue is free, which is when a `Task`'s continuation, a `URLSession` completion hopping
    /// back to the main actor, and an actor's answer all get to run.
    private static func pump() {
        guard let window else { return }
        var message = MSG()
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            if Int32(message.message) == WM_QUIT {
                exit(Int32(message.wParam))
            }
            // The rail's own keys and its ⌥-scroll, taken before the window they were aimed at —
            // usually WebKit's — ever sees them. Unchanged from the loop this replaced.
            if window.route(message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        // Nothing to do until either input arrives or the slice runs out. `MWMO_INPUTAVAILABLE` is
        // what makes this safe against the race the plain wake mask has: a message that arrived
        // *after* the loop above drained the queue and *before* this call would otherwise be waited
        // through for the whole slice.
        _ = MsgWaitForMultipleObjectsEx(0, nil, slice, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE))
        DispatchQueue.main.async { MainActor.assumeIsolated { pump() } }
    }
}
