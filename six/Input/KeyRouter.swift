#if os(macOS)
import AppKit
import WebKit

/// The one place a key press is decided.
///
/// It runs on a local `NSEvent` monitor because it has to: the menu bar is asked only after the key
/// window's view hierarchy has had its say, and a focused `WKWebView` says yes to `⌥←`. A monitor
/// runs before all of it. What is new is not the monitor — the scroll monitor had one bolted to its
/// side — but that there is exactly one, that it consults a table rather than a chain of `if`s, and
/// that it works out what the keyboard is pointed at (`KeyContext`) instead of guessing from the
/// first responder.
///
/// **A key can arrive here twice.** Most of the table is `.pageFirst`: while a page has the keyboard
/// the key is let through to it, and WebKit, when the page did not want it — no `preventDefault`, no
/// caret moved, nothing scrolled, nothing typed — sends the very same event again through
/// `NSApp.sendEvent` (`WebViewImpl::doneWithKeyEvent`), which is how the menu bar gets the `⌘` keys a
/// page leaves alone. That second delivery passes through this monitor too, measured, and it is the
/// one six answers. A key the page kept never comes back, and nothing here waits for it.
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
    /// The tab bar is up instead of the row (`KeyAction.answersInTabs`).
    var showsTabs: () -> Bool = { false }
    /// A key an installed extension bound to itself — dynamic, so it is asked about only once the
    /// table above has had nothing to say, which every `⌘` chord always does (`KeyBindings` is
    /// `⌥`/`⌃` alone; see `ExtensionStore.performCommand(for:in:)`).
    var performExtensionCommand: (NSEvent) -> Bool = { _ in false }

    /// The key last let through to a page, to know it again if WebKit sends it back. By timestamp
    /// and key code rather than by object: the redelivery is the same event, and a later press of
    /// the same key — a repeat included — has a timestamp of its own.
    private var offeredToPage: (timestamp: TimeInterval, keyCode: UInt16)?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // What comes back out of `assumeIsolated` has to be something that can cross an
            // isolation line, and an `NSEvent` is not — so the verdict crosses and the event stays.
            let swallowed = MainActor.assumeIsolated { self.handle(event) == nil }
            return swallowed ? nil : event
        }
        // Never swallowed: a modifier going up is everybody's business, and the ring is only
        // listening for the one that is holding it open.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let held = KeyModifiers(event.modifierFlags)
            MainActor.assumeIsolated {
                if self.isSwitching(), !held.contains(.control) { _ = self.perform(.landSwitcher) }
            }
            return event
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let context = KeyContext(event: event, isSwitching: isSwitching(), isOverview: isOverview(),
                                 showsTabs: showsTabs())
        if let offered = offeredToPage, offered.timestamp == event.timestamp, offered.keyCode == event.keyCode {
            offeredToPage = nil
            return handBack(event, context)
        }
        guard let binding = KeyBindings.all.first(where: { $0.matches(event, in: context) }) else {
            if performExtensionCommand(event) {
                trace(event, context, "an extension's own command")
                return nil
            }
            return passThrough(event, context, why: "no binding")
        }
        if binding.yieldsToCaret(in: context) {
            return passThrough(event, context, why: "the caret has it")
        }
        if binding.precedence == .pageFirst, event.window?.firstResponder is WKWebView {
            offeredToPage = (event.timestamp, event.keyCode)
            return passThrough(event, context, why: "offered to the page first")
        }
        // A row key while the ring is up means the pass is over: land first, then do what was asked.
        // Without this a switch could be left standing by anything that took `⌃` away without a
        // `flagsChanged` — the app losing focus mid-press, most of all.
        if binding.scope == .row, context.isSwitching { _ = perform(.landSwitcher) }
        guard perform(binding.action) else {
            return passThrough(event, context, why: "\(binding.action) had nothing to do")
        }
        trace(event, context, "\(binding.action)")
        return nil
    }

    /// The page did not want it. The same row is asked for again rather than remembered, because the
    /// context is what it is *now* — and only a `.pageFirst` row may answer, since a reserved one
    /// would never have been offered.
    private func handBack(_ event: NSEvent, _ context: KeyContext) -> NSEvent? {
        guard let binding = KeyBindings.all.first(where: { $0.precedence == .pageFirst && $0.matches(event, in: context) }) else {
            return passThrough(event, context, why: "the page handed it back, and nothing here wants it now")
        }
        if binding.scope == .row, context.isSwitching { _ = perform(.landSwitcher) }
        guard perform(binding.action) else {
            return passThrough(event, context, why: "the page handed it back, and \(binding.action) had nothing to do")
        }
        trace(event, context, "\(binding.action), after the page")
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
        TilingLayout.trace("key \(event.chordLabel) [\(context)] → \(outcome)")
    }
}
#endif
