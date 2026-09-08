import SixUI
import WinSDK

// The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION` to `MainActor`, the same as the Mac app's, so this
// top-level code is already on the actor `RailWindow` and `RailModel` live on.

// Declaring the process DPI-*unaware* on a 150% display looks backwards, and is what makes a page
// usable at all. WebKit's Windows port takes its device scale from the monitor DPI the process is
// allowed to see, renders at that scale, and then presents the result one backing pixel to one
// window pixel — so under a DPI-aware process it draws 1.5x too large, spills out of its own HWND,
// and every click lands 1.5x away from whatever it appeared to hit. Nothing on the embedding side
// rescales that: not `WKPageSetCustomBackingScaleFactor`, not the thread's DPI context, not the
// units of the rect `WKViewCreate` is handed — each measured, see docs/windows.md. Reporting 96 DPI
// is the one lever that makes WebKit's own scale agree with the window it draws into.
// `..._GDISCALED` rather than plain `..._UNAWARE` so Windows re-renders the rail's own GDI text at
// the real display scale instead of stretching the bitmap; the page is stretched either way.
if !SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_UNAWARE_GDISCALED) {
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_UNAWARE) // before Windows 10 1809
}

// `nil` is "this process's own module", which cannot fail for a process asking about itself.
let instance = GetModuleHandleW(nil)!
let window = RailWindow()

guard window.create(instance: instance) else {
    fatalError("[six] failed to create the rail window")
}
window.show()
_ = window.run()
