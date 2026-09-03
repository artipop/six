#if os(macOS)
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
    /// a key press never reaches the view hierarchy, and the way out of the overview must not depend
    /// on where the focus happens to be. Returning true swallows the event.
    var onEscape: () -> Bool = { false }
    /// niri's ⌥ bindings, for the same reason and then some. They used to be a menu — a **Layout**
    /// menu of eleven items, ten of which were an arrow key. That menu is gone (`ViewCommands` says
    /// why), and it could not have kept them working anyway: a first-responder `WKWebView` answers a
    /// key equivalent before the menu bar ever sees it and keeps `⌥←` / `⌥→` for word movement, so
    /// after clicking into a page the layout keys went quiet until something else was clicked. A
    /// local monitor runs before all of it.
    ///
    /// The one thing that has to be given back is a text field: `⌥←` in the address field is word
    /// movement and always was, so the arrows step aside while the caret is in one of six's own.
    /// (A field *inside a page* cannot be told apart from the page around it, and the rail wins
    /// there — it is what the key is for in this browser.)
    var onLayoutKey: (LayoutKey) -> Void = { _ in }
    /// ⌃Tab, and ⌃⇧Tab the other way: one step along the ring of windows in the order they were last
    /// looked at. It comes through here rather than through a menu item for the same reason the ⌥
    /// keys do — a focused web view answers a key equivalent first — and it needs the monitor for a
    /// second reason besides: the ring is held open by a modifier, and nothing but a `flagsChanged`
    /// ever says that a modifier has been let go of.
    var onSwitchWindow: (Int) -> Void = { _ in }
    /// ⌃ came up (or the pass ended some other way): land on the window the ring is showing.
    var onSwitchEnded: () -> Void = {}
    var isSwitchingWindows: () -> Bool = { false }

    /// One ⌥ binding, named. `NiriScrollMonitor` decides which key it was; `NiriStripView` decides
    /// what it does, the way it already does for a scroll gesture.
    enum LayoutKey: Sendable {
        case focusColumn(Int)
        case moveColumn(Int)
        case focusColumnEdge(last: Bool)
        case focusWorkspace(Int)
        case moveColumnToWorkspace(Int)
        case toggleFullWidth
        case toggleOverview
        case toggleCenterFocus
    }

    private var monitor: Any?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var clickMonitor: Any?
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
        // Never swallowed: a modifier going up is everybody's business, and the switcher is only
        // listening for the one that is holding its ring open.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if self.isSwitchingWindows(), !held.contains(.control) { self.onSwitchEnded() }
                return event
            }
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
                NiriLayout.trace("click at (\(Int(point.x)), \(Int(flipped))) → \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            }
            return event
        }
    }

    static var tracesClicks: Bool { NiriLayout.tracesUI }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        keyMonitor = nil
        flagsMonitor = nil
        clickMonitor = nil
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126
    private static let home: UInt16 = 115
    private static let end: UInt16 = 119
    private static let tab: UInt16 = 48

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, event.keyCode == Self.escapeKeyCode {
            // A video playing full screen is WebKit's own window with its own ⎋; that one is not
            // ours to take.
            if let window = event.window, String(describing: type(of: window)).contains("FullScreen") { return event }
            return onEscape() ? nil : event
        }
        if event.keyCode == Self.tab, flags == .control || flags == [.control, .shift] {
            onSwitchWindow(flags.contains(.shift) ? -1 : 1)
            return nil
        }
        // The ring is open and the key that arrived is not one of its own. Whatever it is, the pass
        // is over: land, and let the key through to whatever it was meant for. Without this a switch
        // could be left standing by anything that took ⌃ away without a `flagsChanged` — the app
        // losing focus mid-press, most of all.
        if isSwitchingWindows(), event.keyCode != Self.tab { onSwitchEnded() }
        guard let key = Self.layoutKey(for: event, flags: flags) else { return event }
        // ⌥ and an arrow is word and paragraph movement in a text field, and was long before it was
        // niri's. While the caret is in one of six's own fields the rail does not take it; ⌥W ⌥O ⌥C
        // are not text movement, so those still answer.
        if Self.movesTheCaret(event.keyCode), isEditingText(event) { return event }
        onLayoutKey(key)
        return nil
    }

    private static func movesTheCaret(_ keyCode: UInt16) -> Bool {
        [leftArrow, rightArrow, upArrow, downArrow, home, end].contains(keyCode)
    }

    /// niri's table, in the order [hotkeys.md](../../docs/hotkeys.md) lists it. Letters are read from
    /// `charactersIgnoringModifiers` because ⌥W is `∑` and ⌥C is `ç` once the layout has had them.
    private static func layoutKey(for event: NSEvent, flags: NSEvent.ModifierFlags) -> LayoutKey? {
        let shifted = flags == [modifier, .shift]
        guard flags == modifier || shifted else { return nil }
        switch event.keyCode {
        case leftArrow: return shifted ? .moveColumn(-1) : .focusColumn(-1)
        case rightArrow: return shifted ? .moveColumn(1) : .focusColumn(1)
        case upArrow: return shifted ? .moveColumnToWorkspace(-1) : .focusWorkspace(-1)
        case downArrow: return shifted ? .moveColumnToWorkspace(1) : .focusWorkspace(1)
        case home where !shifted: return .focusColumnEdge(last: false)
        case end where !shifted: return .focusColumnEdge(last: true)
        default: break
        }
        guard !shifted else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": return .toggleFullWidth
        case "o": return .toggleOverview
        case "c": return .toggleCenterFocus
        default: return nil
        }
    }

    /// The caret is in one of six's own fields — the address bar, the ⌘K line, a document. AppKit
    /// edits through a shared field editor, so the first responder for any of them is an `NSText`.
    private func isEditingText(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSText
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
#endif
