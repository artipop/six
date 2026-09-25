#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Intercepts scroll wheel / trackpad events before they reach the web views so Mod + scroll drives
/// the layout instead of the page — the layout's modifier-plus-wheel bindings. Without Mod the same
/// gestures work over the layout's own chrome (window title bars, the gaps, the background), which
/// keeps plain scrolling inside pages and panels untouched.
///
/// Vertical: **one workspace per gesture**. Deltas accumulate into a rubber-band preview; once they
/// pass the threshold the switch is committed and everything else in that gesture (including
/// trackpad momentum) is swallowed, so a single flick never skips two workspaces. A workspace is a
/// place you went to on purpose and overshooting one is a real loss.
///
/// Horizontal, with centring on: **a window per `threshold` of travel**, and as many as the hand
/// asks for. It used to be one per gesture as well, and that was the same rule applied to a thing it
/// does not fit — a row is a row of windows a few inches long, and a rule that made you lift your
/// fingers between every two of them read as the row being stuck rather than as it being careful.
/// The travel is what limits it, so a flick still lands where you aimed and momentum is still
/// swallowed whole.
///
/// Horizontal with centring off: free panning of the strip, then focus snaps to the column nearest
/// the centre.
@MainActor
final class TilingScrollMonitor {
    /// The layout's modifier key. ⌥ stays out of the way of the browser's own ⌘ shortcuts.
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

    /// Where things stand over the strip without being part of it — the ⌘E line at the bottom of the
    /// row — in SwiftUI's window coordinates, by name. Written by the views themselves, which is why
    /// it is static: they are drawn far from the strip that owns the monitor.
    static var overlays: [String: CGRect] = [:]

    private var monitor: Any?
    private var clickMonitor: Any?
    private var accumulated: CGFloat = 0
    private var accumulatedX: CGFloat = 0
    /// The vertical has switched a workspace in this gesture, and will not switch another.
    private var didCommit = false
    /// This gesture has stepped along the row, so it is a horizontal gesture and stays one. Without
    /// it, a hand drifting off the line after a step would switch a workspace on the way — which the
    /// old one-commit-per-gesture rule prevented as a side effect of preventing everything else.
    private var steppedColumns = false
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
            // The event itself cannot cross an isolation line; whether it was taken can.
            let swallowed = MainActor.assumeIsolated { self.handle(event) == nil }
            return swallowed ? nil : event
        }
        startClickTrace()
    }

    /// `SIX_UI_DEBUG=1`: every click, and the AppKit view that answered for the point. A control that
    /// stops working is either not being hit or not doing anything, and this says which.
    private func startClickTrace() {
        guard Self.tracesClicks, clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                let point = event.locationInWindow
                let hit = event.window?.contentView?.hitTest(point)
                let flipped = (event.window?.contentView?.bounds.height ?? 0) - point.y
                TilingLayout.trace("click at (\(Int(point.x)), \(Int(flipped))) → \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
            return event
        }
    }

    static var tracesClicks: Bool { TilingLayout.tracesUI }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        clickMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Only the keys a hand can be on: Caps Lock left down is not a gesture modifier, and taking
        // the whole device-independent mask for an equality test is what broke the keyboard's arrows
        // (`NSEvent.ModifierFlags.heldByHand`).
        let flags = event.modifierFlags.intersection(.heldByHand)
        if flags != Self.modifier {
            guard flags.isEmpty, isOverStrip(event) else { return event }
            if !modifierOptional(), let target = scrollTargetBeneathOverlay(event) {
                target.scrollWheel(with: event)
                return nil
            }
            guard modifierOptional() || isOverLayoutChrome(event) else { return event }
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
                steppedColumns = true
                lastCommitTime = event.timestamp
                // What is left over after the step, and not zero: the travel a hand puts in is
                // continuous, and throwing away the overshoot of every step makes the next one
                // longer than the one before it — which is felt as the row getting heavier the
                // further you push.
                accumulatedX += threshold * (accumulatedX < 0 ? 1 : -1)
                onPreviewColumn(accumulatedX / threshold)
                onStepColumn(direction)
            } else {
                onPreviewColumn(accumulatedX / threshold)
            }
            return nil
        }

        guard dy != 0 else { return nil }
        // A gesture that has walked the row is a horizontal one until the fingers lift. The hand
        // does not stay on the line, and a workspace arriving because of the drift is the one
        // mistake here you cannot undo by pushing back.
        guard !steppedColumns else { return nil }

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
            onPreview(accumulated / threshold)
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

    /// A scroll over the ⌘E line belongs to what is under it. The line is not the layout's chrome,
    /// but where it is not a scrolling answer it is not a page or a list either, so it fell through to
    /// the workspace switch: the pointer on the question, or on the Copy row under an answer, and the
    /// row went to the next workspace. What the line itself scrolls (the answer's text) is an
    /// `NSScrollView` and never reaches here. Only the line, by the frames it reports: the curtains at
    /// the ends of the row are hosted over pages too, and a swipe there is meant for the row.
    ///
    /// Nil when the pointer is not on the line. On it with nothing scrollable beneath, the window's
    /// content view: the event is spent and nothing moves, which is still better than a workspace
    /// going by.
    private func scrollTargetBeneathOverlay(_ event: NSEvent) -> NSView? {
        guard let content = event.window?.contentView else { return nil }
        let point = event.locationInWindow
        let flipped = CGPoint(x: point.x, y: content.bounds.height - point.y)
        guard Self.overlays.values.contains(where: { $0.contains(flipped) }),
              let hit = content.hitTest(point), !Self.isScrollable(hit) else { return nil }
        let target = Self.scrollable(at: point, in: content) ?? content
        if Self.tracesClicks {
            TilingLayout.trace("scroll on the ⌘E line → \(String(describing: type(of: target)))")
        }
        return target
    }

    private static func isScrollable(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let view = current {
            if view is WKWebView || view is NSScrollView || view is NSTextView { return true }
            current = view.superview
        }
        return false
    }

    /// The front-most page or list under `point`. Later subviews are drawn over earlier ones, so the
    /// walk goes from the back and the last match wins.
    private static func scrollable(at point: NSPoint, in root: NSView) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if view is WKWebView || view is NSScrollView {
                if view.convert(view.bounds, to: nil).contains(point) { found = view }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Discrete wheels have no phase to end a gesture on, so they are throttled by time instead.
    private func commitStep(at timestamp: TimeInterval, _ step: () -> Void) {
        guard timestamp - lastCommitTime > minimumCommitInterval else { return }
        lastCommitTime = timestamp
        step()
    }

    /// The gesture is over as far as this monitor is concerned — a pause long enough to be a new
    /// gesture, or a real end.
    ///
    /// It lets go of the rubber band, and that is not tidiness: the band and the light at the end of
    /// the row are held by the *layout*, and the only thing that releases them is a zero arriving
    /// here. Resetting the accumulator without sending one left a lit edge with nobody to put it
    /// out — a finger resting mid-gesture was enough — and `endGesture` could not clean up after it,
    /// because by then the accumulator it tests was already zero.
    private func resetGesture() {
        if accumulated != 0 { onPreview(0) }
        if accumulatedX != 0 { onPreviewColumn(0) }
        accumulated = 0
        accumulatedX = 0
        didCommit = false
        steppedColumns = false
    }

    private func endGesture() {
        resetGesture() // which is what lets go of the band and the light
        if isPanning {
            isPanning = false
            onPanEnded()
        }
    }
}
#endif
