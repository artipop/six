import SixUI
import WinSDK

// The whole entry point: one Win32 window, registered and created by `RailWindow`, pumped by the
// classic `GetMessage`/`DispatchMessage` loop until `WM_QUIT`. `six-windows`'s own target sets the
// module's default actor isolation to `@MainActor` (the same `SWIFT_DEFAULT_ACTOR_ISOLATION` the Mac
// app target sets), so this top-level code is on the same actor `RailWindow` and `RailModel` are.
// `nil` here means "the calling process's own module" and cannot fail for a process asking about
// itself, so the force-unwrap is the same trust a C `HMODULE` return would need anyway.
let instance = GetModuleHandleW(nil)!
let window = RailWindow()

guard window.create(instance: instance) else {
    fatalError("[six] failed to create the rail window")
}
window.show()
_ = window.run()
