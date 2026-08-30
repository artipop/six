import Foundation
import Observation

/// What a page's translation looks like from the outside: enough for a button, a bar and a menu,
/// and nothing that belongs to one platform.
nonisolated struct TabTranslation: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// The page is in another language and nothing has been asked for yet.
        case offered
        /// The platform is fetching a language. No percentage exists to show — see
        /// `PageTranslating.isFetchingLanguages` — and the system's own sheet says the rest.
        case downloading
        case working(done: Int, of: Int)
        case done
        case failed(String)
    }

    var source: Locale.Language?
    var target: Locale.Language
    var phase: Phase = .offered
    /// The translation is held but the page is showing what it said. A toggle, not a stop.
    var showsOriginal = false
    var engine: String = ""

    /// Is there anything worth a bar above the page? Working, waiting, or broken — not "done",
    /// which the address field says on its own.
    var saysSomething: Bool {
        switch phase {
        case .downloading, .working, .failed: true
        case .offered, .done: false
        }
    }

    var isTranslated: Bool {
        if case .downloading = phase { return true }
        if case .working = phase { return true }
        if case .done = phase { return true }
        return false
    }

    var fraction: Double {
        guard case .working(let done, let total) = phase, total > 0 else { return 0 }
        return Double(done) / Double(total)
    }
}

/// What the page said about itself before anything was touched.
///
/// Decoded leniently, and that is not tidiness. A default value on a stored property does **not**
/// make a synthesized `Decodable` tolerate the key being missing — it still calls `decode` and
/// throws. Each script returns the keys its own answer has, so every one of these has to be
/// `decodeIfPresent` or the first script that leaves a field out fails the whole run with
/// "the data couldn't be read because it is missing", which says nothing about what went wrong.
nonisolated struct TranslationPlan: Decodable, Sendable {
    /// `pdf`, `canvas`, `empty`, or empty for "go ahead".
    var unsupported: String = ""
    /// The page's own `<html lang>`, which is right often enough to try first and wrong often
    /// enough that a detector has to check it.
    var language: String = ""
    var dir: String = ""
    /// Enough text for the caller's own detector when the page claims nothing.
    var sample: String = ""
    var translated: Bool = false

    enum CodingKeys: String, CodingKey { case unsupported, language, dir, sample, translated }

    init(unsupported: String = "", language: String = "", dir: String = "",
         sample: String = "", translated: Bool = false) {
        self.unsupported = unsupported
        self.language = language
        self.dir = dir
        self.sample = sample
        self.translated = translated
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unsupported = try c.decodeIfPresent(String.self, forKey: .unsupported) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        sample = try c.decodeIfPresent(String.self, forKey: .sample) ?? ""
        translated = try c.decodeIfPresent(Bool.self, forKey: .translated) ?? false
    }

    /// The sentence to show, or nil when the page can be translated.
    var refusal: String? {
        switch unsupported {
        case "":
            nil
        case "pdf":
            String.translationRefusal("This is a PDF shown by WebKit's viewer, and there is no text in it to translate")
        case "canvas":
            String.translationRefusal("The text on this page is drawn on a canvas and cannot be translated")
        default:
            String.translationRefusal("There is nothing on this page to translate")
        }
    }
}

extension String {
    /// `String(localized:)` is Apple Foundation's; a GTK front localises through gettext, so on
    /// Linux these are the keys and it translates them itself.
    nonisolated static func translationRefusal(_ key: String) -> String {
        #if os(Linux)
        key
        #else
        String(localized: String.LocalizationValue(key))
        #endif
    }
}

/// Translating a page, from the first look at it to putting it back.
///
/// It knows nothing about WebKit and nothing about Apple: pages arrive as `PageScriptRunner`, words
/// leave through `PageTranslating`. That is what lets the same machine drive a `WebPage` on the Mac,
/// a `WebKitWebView` on Linux and — once it is Kotlin — a `WebView` on Android.
///
/// The source language is *not* decided here. Detecting it is genuinely per-platform
/// (`NLLanguageRecognizer`, ML Kit's `LanguageIdentification`), so the caller resolves it from
/// `TranslationPlan.language` and `.sample` and passes it in.
@MainActor
@Observable
final class PageTranslator {
    /// One per page being translated, keyed by whatever the front calls a tab.
    private(set) var states: [UUID: TabTranslation] = [:]

    /// Translations already paid for, so Show Original is a toggle rather than a new run.
    private var cache: [UUID: [Int: String]] = [:]
    private var loops: [UUID: Task<Void, Never>] = [:]

    /// The engine in use. Set by the front, which owns the choice.
    var engine: (any PageTranslating)?

    /// A page may spend this many characters before six stops following it down an endless feed.
    var budget = 400_000

    init() {}

    subscript(id: UUID) -> TabTranslation? { states[id] }

    // MARK: Looking

    func plan(_ page: some PageScriptRunner) async throws -> TranslationPlan {
        let value = try await page.runScript(TranslationScript.plan)
        return try Self.decode(value, as: TranslationPlan.self)
    }

    /// The page has settled and it is in another language: offer it, so the address field has
    /// something to show. Does nothing if a run is already under way for this page.
    func offer(source: Locale.Language, target: Locale.Language, id: UUID) {
        guard states[id] == nil else { return }
        states[id] = TabTranslation(source: source, target: target, phase: .offered)
    }

    /// Say why nothing is going to happen, in the same place the progress would have been. A click
    /// that silently does nothing is the worst answer available.
    func fail(id: UUID, _ message: String, target: Locale.Language) {
        var state = states[id] ?? TabTranslation(source: nil, target: target)
        state.phase = .failed(message)
        states[id] = state
    }

    /// The reader stopped it. Whatever landed stays on the page.
    func markStopped(id: UUID) {
        states[id]?.phase = .done
    }

    // MARK: Translating

    func translate(
        _ page: some PageScriptRunner,
        id: UUID,
        from source: Locale.Language,
        to target: Locale.Language
    ) async {
        guard let engine else { return }
        stop(id)                                        // one run per page

        states[id] = TabTranslation(source: source, target: target,
                                    phase: .working(done: 0, of: 0), engine: engine.name)
        cache[id] = [:]
        defer { engine.finishedRun() }

        do {
            // Whatever the page is carrying belongs to the language being left. Without this a
            // second run finds every node already registered, collects nothing, and calls itself
            // finished — which is what "switching language does nothing" looked like.
            _ = try? await page.runScript(TranslationScript.reset)

            let collected = try await page.runScript(
                TranslationScript.collect, arguments: ["budget": budget]
            )
            let found = try Self.decode(collected, as: Collected.self)
            if let refusal = TranslationPlan(unsupported: found.unsupported).refusal {
                states[id]?.phase = .failed(refusal)
                return
            }

            var done = 0
            let total = found.segments.count
            states[id]?.phase = .working(done: 0, of: total)

            // Nothing has come back yet, and there are two very different reasons for that: the
            // engine is working, or the platform is still fetching a language. Only the second one
            // can take minutes, and a bar sitting at zero without saying which is the complaint
            // this exists to answer. The watcher stops as soon as a batch lands.
            let watcher = watchForDownload(id: id)
            defer { watcher.cancel() }

            let limits = engine.limits
            for batch in TranslationBatch.chunks(found.segments,
                                                 limit: limits.segments,
                                                 characters: limits.characters) {
                try Task.checkCancellation()
                let translated = try await engine.translate(batch, from: source, to: target)
                try await write(translated, to: page, id: id, target: target)
                done += batch.count
                states[id]?.phase = .working(done: done, of: total)
            }

            states[id]?.phase = .done
            // Only now start watching: a feed that hydrates while the first pass is still running
            // would have its new text collected twice.
            _ = try? await page.runScript(TranslationScript.observe)
            follow(page, id: id, from: source, to: target)
        } catch is CancellationError {
            // The page went somewhere else. Its state went with it.
        } catch {
            states[id]?.phase = .failed(error.localizedDescription)
        }
    }

    /// Mirrors the engine's "I am waiting on the platform" into the page's state, for as long as
    /// nothing has been translated yet.
    private func watchForDownload(id: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let engine = self.engine else { return }
                guard let phase = self.states[id]?.phase else { return }
                switch phase {
                case .working(let done, _) where done == 0:
                    if engine.isFetchingLanguages { self.states[id]?.phase = .downloading }
                case .downloading:
                    if !engine.isFetchingLanguages { self.states[id]?.phase = .working(done: 0, of: 0) }
                default:
                    return                      // a batch landed, or it ended; nothing left to say
                }
            }
        }
    }

    /// Writes one batch and remembers it, so Show Original can come back for free.
    private func write(
        _ translated: [Int: String],
        to page: some PageScriptRunner,
        id: UUID,
        target: Locale.Language
    ) async throws {
        guard !translated.isEmpty else { return }
        for (key, value) in translated { cache[id, default: [:]][key] = value }
        let list = translated.map { ["id": $0.key, "text": $0.value] as [String: Any] }
        _ = try await page.runScript(TranslationScript.apply, arguments: [
            "list": list,
            "lang": target.languageCode?.identifier ?? "",
            "dir": Self.isRightToLeft(target) ? "rtl" : ""
        ])
    }

    // MARK: Following a page that keeps loading

    /// A feed adds posts as it is scrolled, and the observer in the page can only *notice* — a
    /// script body has no `await`. So Swift comes back for what it found, on a backoff that gets
    /// slower while nothing arrives and gives up when the page has clearly settled.
    private func follow(
        _ page: some PageScriptRunner,
        id: UUID,
        from source: Locale.Language,
        to target: Locale.Language
    ) {
        loops[id] = Task { [weak self] in
            var wait = Duration.milliseconds(800)
            var idle = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard let self, let engine = self.engine else { return }
                guard self.states[id]?.showsOriginal == false else { return }

                let value = try? await page.runScript(TranslationScript.drain, arguments: ["limit": 200])
                guard let more = try? Self.decode(value, as: Collected.self) else { return }

                if more.segments.isEmpty {
                    idle += wait
                    wait = min(wait * 2, .seconds(5))
                    if idle > .seconds(60) { return }   // the page has stopped growing
                    continue
                }
                if more.characters > self.budget { return }

                idle = .zero
                wait = .milliseconds(800)
                for batch in TranslationBatch.chunks(more.segments,
                                                     limit: engine.limits.segments,
                                                     characters: engine.limits.characters) {
                    guard let translated = try? await engine.translate(batch, from: source, to: target) else { return }
                    try? await self.write(translated, to: page, id: id, target: target)
                }
            }
        }
    }

    // MARK: Back and forth

    func showOriginal(_ page: some PageScriptRunner, id: UUID) async {
        _ = try? await page.runScript(TranslationScript.restore)
        states[id]?.showsOriginal = true
    }

    /// Free: the entries and their originals are still in the page, and the translations are here.
    func showTranslation(_ page: some PageScriptRunner, id: UUID) async {
        guard let translations = cache[id], let target = states[id]?.target else { return }
        let list = translations.map { ["id": $0.key, "text": $0.value] as [String: Any] }
        _ = try? await page.runScript(TranslationScript.reapply, arguments: [
            "list": list,
            "lang": target.languageCode?.identifier ?? ""
        ])
        states[id]?.showsOriginal = false
    }

    /// The page is going away, or is being left alone. Everything about it goes too — the state in
    /// the page dies with its process anyway.
    func stop(_ id: UUID) {
        loops[id]?.cancel()
        loops[id] = nil
        engine?.cancel()
    }

    func forget(_ id: UUID) {
        stop(id)
        states[id] = nil
        cache[id] = nil
    }

    // MARK: Details

    /// What `collect` and `drain` both hand back — and they do not hand back the same keys, which
    /// is why this decodes every one of them leniently. See the note on `TranslationPlan`.
    private struct Collected: Decodable {
        var unsupported = ""
        var segments: [TranslationSegment] = []
        var characters = 0
        var more = 0

        enum CodingKeys: String, CodingKey { case unsupported, segments, characters, more }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unsupported = try c.decodeIfPresent(String.self, forKey: .unsupported) ?? ""
            segments = try c.decodeIfPresent([TranslationSegment].self, forKey: .segments) ?? []
            characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 0
            more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
        }
    }

    private static func decode<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        guard let object = value, JSONSerialization.isValidJSONObject(object) else {
            throw PageTranslationError.unsupportedPage(
                String.translationRefusal("There is nothing on this page to translate")
            )
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The five scripts that run the other way. Only `<html dir>` is touched, and only when it
    /// changes: an RTL page sets `dir` per element for its own code and quotations, and rewriting
    /// those breaks the page to fix nothing.
    nonisolated static func isRightToLeft(_ language: Locale.Language) -> Bool {
        ["ar", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv"]
            .contains(language.languageCode?.identifier ?? "")
    }
}
