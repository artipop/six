import Foundation
@testable import SixCore
import WinSDK

/// Translating the page you are reading, on this front.
///
/// Almost nothing here is about translation. The page walk, the batching, the progress, Show
/// Original and the whole state machine are `PageTranslator` in `SixCore` — the same code the Mac
/// runs — and the engine under it is `BergamotTranslator`, also shared. What this file is, is the
/// three joins that are genuinely per front: which page, which languages, and when to offer.
///
/// **Which languages** is the one that has no shared answer. The Mac asks
/// `NLLanguageRecognizer` what a page is written in; there is nothing to ask here, so
/// `LanguageGuess` does it from the text, and `<html lang>` is checked against rather than trusted.
///
/// **When to offer** is deliberately cheap. Nothing is asked of the network to decide whether to
/// draw the button: a page in another language gets one, and whether Mozilla actually has weights
/// for that direction is found out on the click, where there is somewhere to say so. The
/// alternative — a catalogue fetch per page load — would put a request on the wire for every page
/// six ever shows, to decide the colour of one glyph.
@MainActor
final class RailTranslation {
    /// The shared state machine. Everything drawn about translation is read out of this.
    let pages = PageTranslator()

    private let sandbox = RailSandbox()
    private let engine: BergamotTranslator
    /// Told whenever anything drawable changed, so the window repaints. The state machine is
    /// `@Observable` and this front does not observe anything — it repaints.
    private let changed: () -> Void

    /// Pages already looked at, so a repaint or a poll does not re-run the walk. Cleared when the
    /// page navigates somewhere else.
    private var considered: Set<Foundation.UUID> = []

    init(changed: @escaping () -> Void) {
        self.changed = changed
        engine = BergamotTranslator(sandbox: sandbox)
        pages.engine = engine
    }

    subscript(tabID: Foundation.UUID) -> TabTranslation? { pages[tabID] }

    /// What to translate into: the setting, or the language the interface is in.
    var target: Locale.Language {
        SettingsStore.shared?.translationTarget ?? Locale.current.language
    }

    // MARK: Offering

    /// A page has finished loading. Is it in another language?
    ///
    /// Runs the cheap half of the walk — `<html lang>`, a thousand characters of body text — and
    /// nothing else. Called from the page-state poll, at most once per navigation.
    func consider(_ view: RailWebView, tabID: Foundation.UUID) {
        guard !considered.contains(tabID) else { return }
        considered.insert(tabID)
        Task { @MainActor in
            // A moment after the navigation finished rather than at it. `didFinishNavigation` is not
            // the moment a page has text in it — the same lateness `RailWindow` polls titles for —
            // and a walk that runs too early reads an empty body and offers nothing, once, forever.
            try? await Task.sleep(for: .milliseconds(800))
            guard let plan = try? await pages.plan(view), plan.refusal == nil, !plan.translated else { return }
            guard let source = LanguageGuess.source(claimed: plan.language, sample: plan.sample) else { return }
            let wanted = BergamotTranslator.code(for: target) ?? "en"
            guard source != wanted else { return }
            pages.offer(source: Locale.Language(identifier: source), target: target, id: tabID)
            Log.info(.translation, "offering \(source) → \(wanted)")
            changed()
        }
    }

    /// The page navigated. Whatever was known about the old one is not about this one.
    func pageChanged(_ tabID: Foundation.UUID) {
        guard considered.contains(tabID) else { return }
        considered.remove(tabID)
        pages.forget(tabID)
        changed()
    }

    /// The column is gone.
    func forget(_ tabID: Foundation.UUID) {
        considered.remove(tabID)
        pages.forget(tabID)
    }

    // MARK: The button

    /// One button, three meanings, in the order a reader meets them: translate this, show me what it
    /// said, put it back.
    func toggle(_ view: RailWebView, tabID: Foundation.UUID) {
        let state = pages[tabID]
        Task { @MainActor in
            switch (state?.isTranslated ?? false, state?.showsOriginal ?? false) {
            case (true, false):
                await pages.showOriginal(view, id: tabID)
            case (true, true):
                await pages.showTranslation(view, id: tabID)
            case (false, _):
                await start(view, tabID: tabID, source: state?.source)
            }
            changed()
        }
    }

    /// A run, from the first look at the page to the last batch.
    private func start(_ view: RailWebView, tabID: Foundation.UUID, source known: Locale.Language?) async {
        let target = target
        var source = known
        if source == nil {
            // The button was pressed on a page nothing was offered for — a page in the reader's own
            // language, or one whose text arrived after the walk looked. Look again rather than
            // refusing: pressing translate should translate.
            guard let plan = try? await pages.plan(view) else {
                pages.fail(id: tabID, PageTranslationError.unsupportedPage(
                    String.translationRefusal("There is nothing on this page to translate")
                ).localizedDescription, target: target)
                return
            }
            if let refusal = plan.refusal {
                pages.fail(id: tabID, refusal, target: target)
                return
            }
            source = LanguageGuess.source(claimed: plan.language, sample: plan.sample)
                .map { Locale.Language(identifier: $0) }
        }
        guard let source else {
            pages.fail(id: tabID, "Could not tell what language this page is in", target: target)
            return
        }

        // Asked before the run rather than during it, because "there is no model for this pair" is
        // an answer and not a failure: it needs saying once, in a sentence, rather than as a run
        // that starts and immediately stops.
        guard await engine.canTranslate(from: source, to: target) else {
            pages.fail(id: tabID, PageTranslationError.unsupportedPair(
                source: source.languageCode?.identifier ?? "?",
                target: target.languageCode?.identifier ?? "?"
            ).localizedDescription, target: target)
            return
        }

        // Thirty megabytes per direction, once. Said out loud in the log because the first
        // translation on a machine is a minute of nothing happening otherwise.
        let missing = await engine.downloadSize(from: source, to: target)
        if missing > 0 {
            Log.info(.translation, "fetching \(missing / 1_048_576) MB of language for this pair")
        }
        // The progress the bar draws is written into `pages` by the run itself, and this front is
        // not observing anything, so the repaint is a poll for as long as the run lasts.
        let ticking = tick(tabID)
        await pages.translate(view, id: tabID, from: source, to: target)
        ticking.cancel()
        changed()
    }

    /// Repaint four times a second while a run is going on. The same rate `RailWindow` polls the
    /// page's title at, and for the same reason: nothing here announces itself.
    private func tick(_ tabID: Foundation.UUID) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, pages[tabID] != nil else { return }
                changed()
            }
        }
    }
}

/// The bar's side of it: one button, and what it does.
extension RailWindow {
    /// Translate the page on screen, or put it back. Nothing happens on a rail with no focused
    /// column, which is also when the button is drawn dim.
    func translateFocusedPage() {
        guard let focused = model.columns.first(where: \.isFocused),
              let view = webViews[focused.id] else { return }
        translation.toggle(view, tabID: focused.id)
    }
}
