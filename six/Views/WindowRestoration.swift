import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the snapshot keeps about the window itself.
nonisolated struct WindowSnapshot: Codable, Sendable {
    var frame: CGRect
    var isFullScreen: Bool
}

/// The main window's frame and fullscreen state, mirrored from AppKit notifications so the autosave
/// sees changes, and applied back once when the window first appears. A phone's window is the screen
/// and never moves: the state is still read and written back, so a file the Mac wrote survives a
/// launch on the phone unchanged, but there is nothing to follow.
@MainActor
@Observable
final class WindowState {
    var frame: CGRect?
    var isFullScreen = false
    #if os(macOS)
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    #endif

    init(snapshot: WindowSnapshot?) {
        frame = snapshot?.frame
        isFullScreen = snapshot?.isFullScreen ?? false
    }

    var snapshot: WindowSnapshot? {
        frame.map { WindowSnapshot(frame: $0, isFullScreen: isFullScreen) }
    }

#if os(macOS)
    /// Called when the content view lands in its window: restore, then follow.
    func attach(_ window: NSWindow) {
        guard !restored else { return }
        restored = true
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: true)
        }
        if isFullScreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        let center = NotificationCenter.default
        let follow: (Notification.Name) -> Void = { [weak self, weak window] name in
            let token = center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self?.sync(window) }
            }
            self?.observers.append(token)
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            follow(name)
        }
        sync(window)
    }

    private func sync(_ window: NSWindow?) {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        isFullScreen = fullScreen
        // The fullscreen frame is the screen; keep the windowed one so leaving fullscreen next time lands right.
        if !fullScreen { frame = window.frame }
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
#endif
}

#if os(macOS)
/// Finds the `NSWindow` behind a SwiftUI hierarchy and hands it to `WindowState`.
struct WindowObserver: NSViewRepresentable {
    let state: WindowState

    func makeNSView(context: Context) -> Probe { Probe(state: state) }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let state: WindowState
        init(state: WindowState) {
            self.state = state
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { state.attach(window) }
        }
    }
}
#endif
