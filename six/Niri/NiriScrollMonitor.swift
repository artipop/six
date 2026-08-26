import AppKit
import SwiftUI
import WebKit

/// Intercepts scroll wheel / trackpad events before they reach the web views so Mod + scroll drives
/// the layout instead of the page — niri's `Mod+WheelScrollDown` bindings. Without Mod the same
/// gestures work over the layout's own chrome (window title bars, the gaps, the background), which
/// keeps plain scrolling inside pages and panels untouched.
///
/// Vertical: one workspace per gesture. Deltas accumulate into a rubber-band preview; once they pass
/// the threshold the switch is committed and everything else in that gesture (including trackpad
/// momentum) is swallowed, so a single flick never skips two workspaces.
/// Horizontal: free panning of the strip, then focus snaps to the column nearest the centre.
@MainActor
final class NiriScrollMonitor {
    /// The niri "Mod" key. ⌥ stays out of the way of the browser's own ⌘ shortcuts.
    static let modifier: NSEvent.ModifierFlags = .option

    var onStepWorkspace: (Int) -> Void = { _ in }
    var onPreview: (CGFloat) -> Void = { _ in }
    var onPan: (CGFloat) -> Void = { _ in }
    var onPanEnded: () -> Void = {}
    var onStepColumn: (Int) -> Void = { _ in }
    var onPreviewColumn: (CGFloat) -> Void = { _ in }
    /// True while the layout keeps the focused window centred. Then horizontal scrolling steps from
    /// window to window, one per gesture, instead of panning freely — nothing can rest half-way.
    var snapsHorizontally: () -> Bool = { false }
    /// Where the strip is, in SwiftUI's window coordinates. Layout gestures without Mod belong to the
    /// strip and to nothing else: the top bar is chrome too, and treating it as the layout's own made
    /// a click on one of its buttons a gamble — a hair of finger travel on a trackpad and the
    /// workspace switched under the cursor.
    var stripFrame: () -> CGRect = { .infinite }
    /// True when the gesture works without holding Mod (the overview has no page to scroll).
    var modifierOptional: () -> Bool = { false }
    /// ⎋ arrives through the same monitor rather than through SwiftUI: while a page is first responder
    /// a key press never reaches the view hierarchy, and the way out of fullscreen must not depend on
    /// where the focus happens to be. Returning true swallows the event.
    var onEscape: () -> Bool = { false }

    private var monitor: Any?
    private var keyMonitor: Any?
    private var accumulated: CGFloat = 0
    private var accumulatedX: CGFloat = 0
    private var didCommit = false
    private var isPanning = false
    private var lastEventTime: TimeInterval = 0
    private var lastCommitTime: TimeInterval = 0

    private let threshold: CGFloat = 55
    private let minimumCommitInterval: TimeInterval = 0.28
    private let idleReset: TimeInterval = 0.25

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        monitor = nil
        keyMonitor = nil
    }

    private static let escapeKeyCode: UInt16 = 53

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == Self.escapeKeyCode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
        // A video playing full screen is WebKit's own window with its own ⎋; that one is not ours to take.
        if let window = event.window, String(describing: type(of: window)).contains("FullScreen") { return event }
        return onEscape() ? nil : event
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags != Self.modifier {
            guard flags.isEmpty, isOverStrip(event), modifierOptional() || isOverLayoutChrome(event) else { return event }
        }

        if event.timestamp - lastEventTime > idleReset { resetGesture() }
        lastEventTime = event.timestamp

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endGesture()
            return nil
        }
        // Momentum keeps arriving after the fingers lift: swallow it, never act on it.
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { endGesture() }
            return nil
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if abs(dx) > abs(dy) {
            guard event.hasPreciseScrollingDeltas else {
                commitStep(at: event.timestamp) { self.onStepColumn(dx < 0 ? 1 : -1) }
                return nil
            }
            guard snapsHorizontally() else {
                isPanning = true
                onPan(-dx)
                return nil
            }
            guard !didCommit else { return nil }
            accumulatedX += dx
            if abs(accumulatedX) >= threshold {
                let direction = accumulatedX < 0 ? 1 : -1
                didCommit = true
                lastCommitTime = event.timestamp
                accumulatedX = 0
                onPreviewColumn(0)
                onStepColumn(direction)
            } else {
                onPreviewColumn(accumulatedX * 0.35)
            }
            return nil
        }

        guard dy != 0 else { return nil }

        if !event.hasPreciseScrollingDeltas {
            commitStep(at: event.timestamp) { self.onStepWorkspace(dy < 0 ? 1 : -1) }
            return nil
        }
        guard !didCommit else { return nil }

        accumulated += dy
        if abs(accumulated) >= threshold {
            let direction = accumulated < 0 ? 1 : -1
            didCommit = true
            lastCommitTime = event.timestamp
            accumulated = 0
            onPreview(0)
            onStepWorkspace(direction)
        } else {
            onPreview(accumulated * 0.35)
        }
        return nil
    }

    /// True when the pointer sits on the layout itself rather than on something that scrolls: a page,
    /// a list, a text view. Those keep every unmodified scroll event.
    /// `NSEvent` measures from the bottom left of the window, SwiftUI from the top left of the same
    /// content view, so the flip is all that stands between the two.
    private func isOverStrip(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return true }
        let point = event.locationInWindow
        return stripFrame().contains(CGPoint(x: point.x, y: content.bounds.height - point.y))
    }

    private func isOverLayoutChrome(_ event: NSEvent) -> Bool {
        guard let hit = event.window?.contentView?.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is WKWebView || current is NSScrollView || current is NSTextView { return false }
            view = current.superview
        }
        return true
    }

    /// Discrete wheels have no phase to end a gesture on, so they are throttled by time instead.
    private func commitStep(at timestamp: TimeInterval, _ step: () -> Void) {
        guard timestamp - lastCommitTime > minimumCommitInterval else { return }
        lastCommitTime = timestamp
        step()
    }

    private func resetGesture() {
        accumulated = 0
        accumulatedX = 0
        didCommit = false
    }

    private func endGesture() {
        if accumulated != 0 { onPreview(0) }
        if accumulatedX != 0 { onPreviewColumn(0) }
        resetGesture()
        if isPanning {
            isPanning = false
            onPanEnded()
        }
    }
}
