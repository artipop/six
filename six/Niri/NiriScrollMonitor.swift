import AppKit
import SwiftUI

/// Intercepts scroll wheel / trackpad events before they reach the web views so Mod + scroll drives
/// the layout instead of the page — niri's `Mod+WheelScrollDown` bindings.
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
    /// True when the gesture works without holding Mod (the overview has no page to scroll).
    var modifierOptional: () -> Bool = { false }

    private var monitor: Any?
    private var accumulated: CGFloat = 0
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
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == Self.modifier || (flags.isEmpty && modifierOptional()) else { return event }

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
            if event.hasPreciseScrollingDeltas {
                isPanning = true
                onPan(-dx)
            } else {
                commitStep(at: event.timestamp) { self.onStepColumn(dx < 0 ? 1 : -1) }
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

    /// Discrete wheels have no phase to end a gesture on, so they are throttled by time instead.
    private func commitStep(at timestamp: TimeInterval, _ step: () -> Void) {
        guard timestamp - lastCommitTime > minimumCommitInterval else { return }
        lastCommitTime = timestamp
        step()
    }

    private func resetGesture() {
        accumulated = 0
        didCommit = false
    }

    private func endGesture() {
        if accumulated != 0 { onPreview(0) }
        resetGesture()
        if isPanning {
            isPanning = false
            onPanEnded()
        }
    }
}
