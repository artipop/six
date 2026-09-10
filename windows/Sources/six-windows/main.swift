import SixUI
import WinSDK

// The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION` to `MainActor`, the same as the Mac app's, so this
// top-level code is already on the actor `RailWindow` and `RailModel` live on.

// Per-Monitor-V2, so `WM_SIZE` reports real physical pixels and nothing the rail draws is
// bitmap-scaled by the compositor. What that costs is a WebKit that renders 1.5x too large at 150%
// and spills out of its own HWND; `RailWebView.installScaleShim` is what pays for it, and the two
// have to be read together.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

// `nil` is "this process's own module", which cannot fail for a process asking about itself.
let instance = GetModuleHandleW(nil)!
let window = RailWindow()

guard window.create(instance: instance) else {
    fatalError("[six] failed to create the rail window")
}
window.show()
// Not a plain `while GetMessageW` loop, and `RailLoop` has the whole argument: a thread parked in
// `GetMessageW` never drains the queue the main actor runs on, so every `await` on this front
// would be enqueued and forgotten.
_ = RailLoop.run(window)
