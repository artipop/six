#if os(macOS)
import AppKit

/// The one place a key press is decided.
///
/// It runs on a local `NSEvent` monitor because it has to: the menu bar is asked only after the key
/// window's view hierarchy has had its say, and a focused `WKWebView` says yes to `⌥←`. A monitor
/// runs before all of it. What is new is not the monitor — the scroll monitor had one bolted to its
/// side — but that there is exactly one, that it consults a table rather than a chain of `if`s, and
/// that it works out what the keyboard is pointed at (`KeyContext`) instead of guessing from the
/// first responder.
///
/// `SIX_UI_DEBUG=1` prints a line per key: the chord, the context, and who took it. "⌥→ doesn't
/// always work" was three sessions of pressing things; it is now one line of output.
@MainActor
final class KeyRouter {
    /// The table's actions, performed. Returns false when the action had nothing to do — `⎋` outside
    /// the overview, `⌥⇧H` on a start page — and then the key goes on to whatever else wanted it.
    var perform: (KeyAction) -> Bool = { _ in false }
    var isSwitching: () -> Bool = { false }
    var isOverview: () -> Bool = { false }

    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
        // Never swallowed: a modifier going up is everybody's business, and the ring is only
        // listening for the one that is holding it open.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                let held = KeyModifiers(event.modifierFlags)
                if self.isSwitching(), !held.contains(.control) { _ = self.perform(.landSwitcher) }
                return event
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let context = KeyContext(event: event, isSwitching: isSwitching(), isOverview: isOverview())
        guard let binding = KeyBindings.all.first(where: { $0.matches(event, in: context) }) else {
            return passThrough(event, context, why: "no binding")
        }
        if let field = context.field, binding.key.yields(to: field) {
            return passThrough(event, context, why: "the caret has it")
        }
        // A rail key while the ring is up means the pass is over: land first, then do what was asked.
        // Without this a switch could be left standing by anything that took `⌃` away without a
        // `flagsChanged` — the app losing focus mid-press, most of all.
        if binding.scope == .rail, context.isSwitching { _ = perform(.landSwitcher) }
        guard perform(binding.action) else {
            return passThrough(event, context, why: "\(binding.action) had nothing to do")
        }
        trace(event, context, "\(binding.action)")
        return nil
    }

    private func passThrough(_ event: NSEvent, _ context: KeyContext, why: String) -> NSEvent? {
        // The ring is open and the key that arrived is not one of its own. Whatever it is, the pass
        // is over: land, and let the key go on to whatever it was meant for.
        if context.isSwitching { _ = perform(.landSwitcher) }
        trace(event, context, "passed through — \(why)")
        return event
    }

    private func trace(_ event: NSEvent, _ context: KeyContext, _ outcome: String) {
        NiriLayout.trace("key \(event.chordLabel) [\(context)] → \(outcome)")
    }
}
#endif
