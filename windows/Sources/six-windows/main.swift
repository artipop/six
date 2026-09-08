import SixUI
import WinSDK

// The whole entry point: one Win32 window, registered and created by `RailWindow`, pumped by the
// classic `GetMessage`/`DispatchMessage` loop until `WM_QUIT`. `six-windows`'s own target sets the
// module's default actor isolation to `@MainActor` (the same `SWIFT_DEFAULT_ACTOR_ISOLATION` the Mac
// app target sets), so this top-level code is on the same actor `RailWindow` and `RailModel` are.
// Declare Per-Monitor-V2 DPI awareness before anything else. Without it Windows renders the whole
// window through an offscreen virtualization surface, which made a live `WKView` come out shrunk
// into roughly two-thirds of its card, matching a 150% display — `../sixty`'s MiniBrowserSwift hit
// this first. Switching to `SYSTEM_AWARE` made no difference to a separate bug this front hit next
// (a live view's content escaping its own HWND's bounds — see docs/windows.md), which turned out to
// be about *when* the view was created and positioned, not which DPI mode was active; V2 is the
// more correct choice of the two regardless, so it is what stayed.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

// `nil` here means "the calling process's own module" and cannot fail for a process asking about
// itself, so the force-unwrap is the same trust a C `HMODULE` return would need anyway.
let instance = GetModuleHandleW(nil)!
let window = RailWindow()

guard window.create(instance: instance) else {
    fatalError("[six] failed to create the rail window")
}
window.show()
_ = window.run()
