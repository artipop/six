import Foundation

/// Bergamot behind `PageTranslating`: the engine the fronts without `Translation.framework` use.
///
/// Everything above this — the page walk, the batching, the state machine, Show Original — is
/// `PageTranslator` and is shared with the Mac. Everything below it is a wasm module in an
/// off-screen page. This is the seam `TranslationSegment.swift` was written around, and it turns
/// out to fit: the only thing that had to be added for a second engine was a language code that is
/// a string rather than a `Locale.Language`.
///
/// Translation is on-device and free, the same bargain the Apple engine makes. The difference is
/// where the weights come from: macOS has them already, and here they are thirty megabytes per
/// direction fetched once from the same Mozilla CDN Firefox fetches them from.
@MainActor
final class BergamotTranslator: PageTranslating {
    /// A product name, so it is not localized — the line `localization.md` draws for engines.
    let name = "Bergamot"

    /// Marian batches by sentence inside one call, so handing it a paragraph at a time wastes most
    /// of what it can do. Twenty short segments together decode several times faster than twenty
    /// calls; much past that and one lost batch is a visible hole in the page, and the progress bar
    /// stops moving for long enough to look stuck.
    let limits = TranslationBatchLimits(segments: 20, characters: 4000)

    private let store: BergamotStore
    private let runtime: BergamotRuntime

    /// True while weights are coming down the wire. Set here rather than read off the store because
    /// the store is an actor and this is asked from a view body — see `PageTranslating`.
    private(set) var isFetchingLanguages = false

    /// Which run's results are still wanted. `cancel()` moves it; a batch that comes back for an
    /// older one is dropped rather than written into a page that has moved on. The decode itself
    /// cannot be interrupted — it is a synchronous call inside wasm — so this is the honest limit
    /// of what cancelling can mean here.
    private var generation = 0

    init(store: BergamotStore, sandbox: any PageSandbox) {
        self.store = store
        self.runtime = BergamotRuntime(store: store, sandbox: sandbox)
    }

    /// The usual way to make one: the release is the vendored glue's, so the catalogue and the
    /// binary cannot drift apart.
    convenience init(sandbox: any PageSandbox) {
        self.init(store: BergamotStore(release: BergamotGlue.release), sandbox: sandbox)
    }

    // MARK: Asking

    func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        guard let from = Self.code(for: source), let to = Self.code(for: target), from != to else {
            return false
        }
        guard let catalogue = try? await store.catalog() else { return false }
        return !catalogue.route(from: from, to: to).isEmpty
    }

    /// What this pair costs before it can be used at all, in bytes. Zero once it is downloaded.
    func downloadSize(from source: Locale.Language, to target: Locale.Language) async -> Int {
        guard let from = Self.code(for: source), let to = Self.code(for: target) else { return 0 }
        return await store.missingBytes(from: from, to: to)
    }

    /// Every language six can translate a page into, as codes. For the menu the front puts up.
    func targets(from source: Locale.Language) async -> [String] {
        guard let from = Self.code(for: source), let catalogue = try? await store.catalog() else { return [] }
        return catalogue.targets(from: from)
    }

    // MARK: Translating

    func translate(
        _ segments: [TranslationSegment],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [Int: String] {
        guard let from = Self.code(for: source), let to = Self.code(for: target) else {
            throw PageTranslationError.unsupportedPair(
                source: source.languageCode?.identifier ?? "?",
                target: target.languageCode?.identifier ?? "?"
            )
        }
        let mine = generation

        // Said before the first batch rather than discovered during it: the whole point of the flag
        // is to explain a progress bar that has not moved, and by the time `prepare` returns there
        // is nothing left to explain.
        if await store.missingBytes(from: from, to: to) > 0 { isFetchingLanguages = true }
        do {
            try await runtime.prepare(from: from, to: to)
        } catch {
            isFetchingLanguages = false
            throw PageTranslationError.engine(name, error.localizedDescription)
        }
        isFetchingLanguages = false
        guard mine == generation else { return [:] }

        let texts: [String]
        do {
            texts = try await runtime.translate(segments.map(\.text))
        } catch {
            throw PageTranslationError.engine(name, error.localizedDescription)
        }
        guard mine == generation else { return [:] }

        // Position is the only thing tying an answer back to its segment — the engine is handed
        // text and gives back text — so a short answer is a bug worth noticing rather than a
        // dictionary quietly missing its tail.
        guard texts.count == segments.count else {
            Log.error(.translation, "bergamot: asked for \(segments.count) segments, got \(texts.count)")
            throw PageTranslationError.engine(name, "the engine answered a different number of segments")
        }
        var translated: [Int: String] = [:]
        for (segment, text) in zip(segments, texts) where !text.isEmpty {
            translated[segment.id] = text
        }
        return translated
    }

    func finishedRun() {}

    func cancel() {
        generation += 1
        isFetchingLanguages = false
    }

    /// Give the weights back. Not called on navigation — a reader who translated one page will
    /// translate the next — but worth having for a front that wants to reclaim the heap.
    func unload() async {
        await runtime.unload()
    }

    // MARK: Languages

    /// A `Locale.Language` as Mozilla spells it in the catalogue.
    ///
    /// Mostly the plain language code, and Chinese is the exception that makes this a function:
    /// there are `en-zh-Hans` and `en-zh-Hant` models and no `en-zh`, so the script is part of the
    /// name. Norwegian is the other one — the catalogue has `nb` and `nn` and nothing under `no`,
    /// which is what a Norwegian page usually claims to be, and Bokmål is the right guess.
    nonisolated static func code(for language: Locale.Language) -> String? {
        guard let base = language.languageCode?.identifier, !base.isEmpty else { return nil }
        switch base {
        case "zh":
            let script = language.script?.identifier
            // A page that says `zh` and nothing else is more often simplified: it is what the
            // mainland writes, and Traditional pages tend to say `zh-TW` or `zh-Hant` because they
            // have had to be specific for years.
            return script == "Hant" ? "zh-Hant" : "zh-Hans"
        case "no":
            return "nb"
        default:
            return base
        }
    }
}
