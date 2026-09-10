import Foundation
import SixWebKitCore

@testable internal import SixCore

/// What the toolbar needs to know about a page's translation, and nothing more.
///
/// A value type of plain Foundation, deliberately: `SixCore` is an `internal import` here, because
/// nothing may put it and Adwaita in one compilation unit, so `TabTranslation` cannot cross into
/// `SixUI` and this is what crosses instead. It carries what a button and a line of text need.
public struct TranslationStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The page is in another language and nothing has been asked for yet.
        case offered
        /// The platform is fetching a language. There is no percentage to show, only a size.
        case downloading
        case working
        case done
        case failed
    }

    public var kind: Kind
    /// The sentence to put under the toolbar, or empty when there is nothing to say. "Done" is
    /// nothing to say: the button's own state says it.
    public var message: String
    /// Where the run is, between zero and one. Zero for everything that is not `working`.
    public var fraction: Double
    /// The translation is held and the page is showing what it said. A toggle, not a stop.
    public var showsOriginal: Bool

    public var saysSomething: Bool { !message.isEmpty }
    public var isTranslated: Bool { kind == .downloading || kind == .working || kind == .done }
}

/// Translating the page you are reading, on the GTK front.
///
/// Almost nothing here is about translation. The page walk, the batching, the progress, Show
/// Original and the whole state machine are `PageTranslator` in `SixCore` — the same code the Mac
/// runs and the same code the Windows front runs — and the engine under it is `BergamotTranslator`,
/// also shared. What is left is the three joins that are genuinely per front: which page, which
/// languages, and when to offer.
///
/// **Which languages** is the one with no shared answer. The Mac asks `NLLanguageRecognizer` what a
/// page is written in and there is nothing to ask here, so `LanguageGuess` reads it out of the text
/// and `<html lang>` is checked against rather than trusted.
///
/// **When to offer** is deliberately cheap: nothing is asked of the network to decide whether to
/// light the button. A page in another language gets one, and whether Mozilla has weights for that
/// direction is found out on the click, where there is somewhere to say so. The alternative would
/// put a request on the wire for every page six ever shows, to decide the colour of one icon.
@MainActor
public final class TranslationController {
    public static let shared = TranslationController()

    /// Told whenever anything drawable changed. adwaita re-renders a view when the state it *read*
    /// changes, and a translation changes none of it — so the front pulls the strip's shape out
    /// again, the same way a permission question makes it.
    public var onChange: (() -> Void)?

    private let pages = PageTranslator()
    private let sandbox = GtkSandbox()
    private let engine: BergamotTranslator

    /// Pages already looked at, so a re-render does not re-run the walk. Cleared on navigation.
    private var considered: Set<UUID> = []

    private init() {
        engine = BergamotTranslator(sandbox: sandbox)
        pages.engine = engine
    }

    // MARK: What the front draws

    public func status(for tabID: UUID) -> TranslationStatus? {
        guard let state = pages[tabID] else { return nil }
        switch state.phase {
        case .offered:
            return TranslationStatus(kind: .offered, message: "", fraction: 0,
                                     showsOriginal: state.showsOriginal)
        case .downloading:
            return TranslationStatus(
                kind: .downloading,
                message: "Downloading the language for this page, about 35 MB, once",
                fraction: 0, showsOriginal: state.showsOriginal
            )
        case .working(let done, let total):
            return TranslationStatus(
                kind: .working,
                message: total > 0 ? "Translating \(done) of \(total)" : "Translating",
                fraction: state.fraction, showsOriginal: state.showsOriginal
            )
        case .done:
            return TranslationStatus(kind: .done, message: "", fraction: 1,
                                     showsOriginal: state.showsOriginal)
        case .failed(let why):
            return TranslationStatus(kind: .failed, message: why, fraction: 0,
                                     showsOriginal: state.showsOriginal)
        }
    }

    // MARK: Offering

    /// A page has finished loading. Is it in another language?
    ///
    /// Runs the cheap half of the walk — `<html lang>` and a thousand characters of body text — and
    /// nothing else.
    public func consider(_ tabID: UUID) {
        guard !considered.contains(tabID), let page = LivePage.focused(tabID) else { return }
        considered.insert(tabID)
        Task { @MainActor in
            // A moment after the load finished rather than at it: `load-changed` is not the moment a
            // page has text in it, and a walk that runs too early reads an empty body and offers
            // nothing, once, for the life of that page.
            try? await Task.sleep(for: .milliseconds(800))
            guard let plan = try? await pages.plan(page), plan.refusal == nil, !plan.translated else { return }
            guard let source = LanguageGuess.source(claimed: plan.language, sample: plan.sample) else { return }
            let wanted = BergamotTranslator.code(for: target) ?? "en"
            guard source != wanted else { return }
            pages.offer(source: Locale.Language(identifier: source), target: target, id: tabID)
            Log.info(.translation, "offering \(source) to \(wanted)")
            onChange?()
        }
    }

    /// The page navigated. Whatever was known about the old one is not about this one.
    public func pageChanged(_ tabID: UUID) {
        guard considered.contains(tabID) else { return }
        considered.remove(tabID)
        pages.forget(tabID)
        onChange?()
    }

    /// The column is gone.
    public func forget(_ tabID: UUID) {
        considered.remove(tabID)
        pages.forget(tabID)
    }

    // MARK: The button

    /// One button, three meanings, in the order a reader meets them: translate this, show me what
    /// it said, put it back.
    public func toggle(_ tabID: UUID) {
        guard let page = LivePage.focused(tabID) else { return }
        let state = pages[tabID]
        Task { @MainActor in
            switch (state?.isTranslated ?? false, state?.showsOriginal ?? false) {
            case (true, false):
                await pages.showOriginal(page, id: tabID)
            case (true, true):
                await pages.showTranslation(page, id: tabID)
            case (false, _):
                await start(page, tabID: tabID, source: state?.source)
            }
            onChange?()
        }
    }

    // MARK: Details

    /// What to translate into: the setting, or the language the interface is in.
    private var target: Locale.Language {
        SettingsStore.shared?.translationTarget ?? Locale.current.language
    }

    private func start(_ page: LivePage, tabID: UUID, source known: Locale.Language?) async {
        let target = target
        var source = known
        if source == nil {
            // The button was pressed on a page nothing was offered for — one in the reader's own
            // language, or one whose text arrived after the walk looked. Look again rather than
            // refusing: pressing translate should translate.
            guard let plan = try? await pages.plan(page) else {
                pages.fail(id: tabID, "There is nothing on this page to translate", target: target)
                onChange?()
                return
            }
            if let refusal = plan.refusal {
                pages.fail(id: tabID, refusal, target: target)
                onChange?()
                return
            }
            source = LanguageGuess.source(claimed: plan.language, sample: plan.sample)
                .map { Locale.Language(identifier: $0) }
        }
        guard let source else {
            pages.fail(id: tabID, "Could not tell what language this page is in", target: target)
            onChange?()
            return
        }

        // Asked before the run rather than during it: "there is no model for this pair" is an answer
        // and not a failure, and it wants saying once, in a sentence, rather than as a run that
        // starts and immediately stops.
        guard await engine.canTranslate(from: source, to: target) else {
            pages.fail(id: tabID, PageTranslationError.unsupportedPair(
                source: source.languageCode?.identifier ?? "?",
                target: target.languageCode?.identifier ?? "?"
            ).localizedDescription, target: target)
            onChange?()
            return
        }

        let missing = await engine.downloadSize(from: source, to: target)
        if missing > 0 {
            Log.info(.translation, "fetching \(missing / 1_048_576) MB of language for this pair")
        }
        // Nothing here observes anything, so the progress line is repainted by asking for a render
        // four times a second for as long as the run lasts.
        let ticking = tick(tabID)
        await pages.translate(page, id: tabID, from: source, to: target)
        ticking.cancel()
        onChange?()
    }

    private func tick(_ tabID: UUID) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, pages[tabID] != nil else { return }
                onChange?()
            }
        }
    }
}
