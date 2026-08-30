#if canImport(Translation)
import Foundation
import Observation
import Translation

/// Translation on the device, by the framework the platform already has.
///
/// Free, offline once a language is downloaded, no key and no quota — the same line six takes with
/// blocking (WebKit compiles the rules itself) and with bookmarks (embeddings on the device). It is
/// also the one engine that is not portable, which is why it sits behind `PageTranslating` and why
/// nothing above it imports `Translation`.
///
/// **Two ways to a session, and the common one needs no view at all.** `LanguageAvailability` says
/// whether a pair is `.installed`; if it is, `TranslationSession(installedSource:target:)` hands one
/// over as an ordinary object with an ordinary lifetime, and that is the path every page takes after
/// the first. A pair that is only `.supported` has to be *downloaded*, and asking for a download is
/// the one thing only SwiftUI's `.translationTask` can do — that path is not here yet, so a
/// `.supported` pair is reported honestly as not installed.
///
/// Deliberately no `actor` and no `Task.detached`: `TranslationSession` is a plain class with no
/// `Sendable` and no isolation, and the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
/// Holding one here is fine; wrapping it in an actor does not compile.
@MainActor
@Observable
final class AppleTranslator: PageTranslating {
    nonisolated var name: String { "Apple Translation" }

    /// Apple's batch call takes a real batch. 60 keeps a torn-down run cheap and still amortises.
    nonisolated var limits: TranslationBatchLimits {
        TranslationBatchLimits(segments: 60, characters: 12_000)
    }

    /// A direction, as something that can be a dictionary key and a `ForEach` identity.
    struct Pair: Hashable, Identifiable, Sendable {
        let source: Locale.Language
        let target: Locale.Language
        var id: String { source.maximalIdentifier + ">" + target.maximalIdentifier }
        init(_ source: Locale.Language, _ target: Locale.Language) {
            self.source = source
            self.target = target
        }
    }

    /// Page prose is read, not skimmed past, so quality wins over latency. The selection popover is
    /// the system's own and picks for itself.
    private let availability = LanguageAvailability(preferredStrategy: .highFidelity)
    private var sessions: [Pair: TranslationSession] = [:]
    /// The one in flight, so `cancel()` has something to cancel.
    private var running: TranslationSession?

    // MARK: PageTranslating

    func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        await availability.status(from: source, to: target) != .unsupported
    }

    func translate(
        _ segments: [TranslationSegment],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [Int: String] {
        guard !segments.isEmpty else { return [:] }

        // `clientIdentifier` is what makes this cheap: the framework carries our own id through and
        // hands it back, so nothing depends on the responses arriving in order.
        let requests = segments.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
        }

        do {
            let responses: [TranslationSession.Response]
            if let owned = try await session(from: source, to: target) {
                running = owned
                isSessionReady = false
                refreshReadiness(of: owned)
                defer { running = nil; isSessionReady = true }
                responses = try await owned.translations(from: requests)
            } else {
                responses = try await enqueue(requests, for: Pair(source, target))
            }
            var out: [Int: String] = [:]
            for response in responses {
                guard let raw = response.clientIdentifier, let id = Int(raw) else { continue }
                out[id] = response.targetText
            }
            return out
        } catch TranslationError.nothingToTranslate {
            // Not a failure: a batch of nothing but names and numbers. The caller leaves them alone.
            return [:]
        } catch {
            throw Self.failure(error, source: source, target: target)
        }
    }

    /// Two ways to be waiting on the platform rather than on the words, and the spinner owes the
    /// reader both: a pair parked in front of the framework's own download sheet, and a session
    /// that exists but is not ready yet — the model is on disk and still being brought up.
    ///
    /// `TranslationSession.isReady` is `get async`, so it cannot be read from here. It is refreshed
    /// beside the session instead and the last answer is cached; a spinner wants a recent value, not
    /// a synchronous one.
    var isFetchingLanguages: Bool { !armed.isEmpty || !isSessionReady }

    private(set) var isSessionReady = true

    private func refreshReadiness(of session: TranslationSession) {
        Task { [weak self] in
            let ready = await session.isReady
            guard let self, self.running === session else { return }
            self.isSessionReady = ready
        }
    }

    func cancel() {
        running?.cancel()
        running = nil
        isSessionReady = true
    }

    // MARK: Sessions

    /// A session we own outright, or nil when the framework has to be asked for one because a
    /// download is needed.
    private func session(from source: Locale.Language, to target: Locale.Language) async throws -> TranslationSession? {
        let pair = Pair(source, target)
        if let known = sessions[pair] { return known }

        switch await availability.status(from: source, to: target) {
        case .installed:
            let session = TranslationSession(
                installedSource: source, target: target, preferredStrategy: .highFidelity
            )
            sessions[pair] = session
            return session
        case .supported:
            // The pair exists and its model is not on this machine. Asking for a download is the one
            // thing only `.translationTask` can do, so this is the path that needs the view. The
            // caller does not know that: it still just awaits a batch.
            return nil
        case .unsupported:
            throw PageTranslationError.unsupportedPair(
                source: Self.name(of: source), target: Self.name(of: target)
            )
        @unknown default:
            throw PageTranslationError.unsupportedPair(
                source: Self.name(of: source), target: Self.name(of: target)
            )
        }
    }

    /// Every pair this machine could translate into, for the language picker.
    var supportedLanguages: [Locale.Language] {
        get async { await availability.supportedLanguages }
    }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await availability.status(from: source, to: target)
    }

    // MARK: The bridge to a session six does not own
    //
    // A pair that is only `.supported` needs its model downloaded, and `.translationTask` is the
    // only thing that can ask. But its session is alive only inside its closure, and the work is
    // driven from a store, not a view. So: the store parks on a continuation, the view is armed
    // with a `Configuration`, and the closure it runs pumps the queue until the queue is closed.
    //
    // The stream carries *nudges*, not jobs. A `CheckedContinuation` travelling through a stream
    // must still be resumed exactly once if the stream is torn down mid-flight, and `AsyncStream`'s
    // termination handler does not run on this actor. Keeping the jobs in a plain main-actor array
    // and using the stream only as a doorbell makes teardown one synchronous drain in a `defer`,
    // with no ordering question to get wrong.

    private struct Job {
        let requests: [TranslationSession.Request]
        let reply: CheckedContinuation<[TranslationSession.Response], any Error>
    }

    private var queues: [Pair: [Job]] = [:]
    private var doorbells: [Pair: AsyncStream<Void>.Continuation] = [:]

    /// The directions a view must currently carry a `.translationTask` for. Observed by
    /// `translationHost`; empty almost always, because an installed pair never comes here.
    private(set) var armed: [Pair: TranslationSession.Configuration] = [:]

    var armedPairs: [Pair] { armed.keys.sorted { $0.id < $1.id } }

    func configuration(for pair: Pair) -> TranslationSession.Configuration? { armed[pair] }

    private func enqueue(
        _ requests: [TranslationSession.Request], for pair: Pair
    ) async throws -> [TranslationSession.Response] {
        arm(pair)
        return try await withCheckedThrowingContinuation { continuation in
            queues[pair, default: []].append(Job(requests: requests, reply: continuation))
            doorbells[pair]?.yield()
        }
    }

    /// Arming the same pair twice is the bug that looks like "the button does nothing":
    /// `Configuration` is `Equatable`, so SwiftUI sees no change and never re-runs the closure.
    /// `invalidate()` bumps its private version, which is what it is for. Every path that re-asks
    /// for a pair — Retry, a second page, a declined download — comes through here.
    private func arm(_ pair: Pair) {
        if armed[pair] != nil {
            armed[pair]?.invalidate()
        } else {
            armed[pair] = TranslationSession.Configuration(
                source: pair.source, target: pair.target, preferredStrategy: .highFidelity
            )
        }
    }

    /// Runs inside `.translationTask`. Stays here, holding the session alive, until the pair is
    /// released or the closure's task is cancelled.
    func serve(_ pair: Pair, _ session: TranslationSession) async {
        let (stream, doorbell) = AsyncStream<Void>.makeStream()
        doorbells[pair] = doorbell
        running = session
        isSessionReady = false
        refreshReadiness(of: session)
        defer {
            doorbells[pair] = nil
            if running === session { running = nil; isSessionReady = true }
            // Whatever is still parked here is never going to be answered by this session.
            for job in queues.removeValue(forKey: pair) ?? [] {
                job.reply.resume(throwing: PageTranslationError.interrupted)
            }
        }
        await drain(pair, session)          // anything that arrived before the closure started
        for await _ in stream {
            await drain(pair, session)
            // The download is what this path existed for. Once it has happened there is nothing
            // left to hold the view open, and holding it open is not free: a second armed pair
            // alongside a live one is a second `.translationTask`, and the framework will not put
            // up a download sheet for it. That is the bug this line is here to not have.
            if queues[pair]?.isEmpty ?? true,
               await availability.status(from: pair.source, to: pair.target) == .installed {
                release(pair)               // finishes the stream, so this loop ends next turn
            }
        }
    }

    private func drain(_ pair: Pair, _ session: TranslationSession) async {
        while !Task.isCancelled, let job = queues[pair]?.first {
            queues[pair]?.removeFirst()
            do {
                job.reply.resume(returning: try await session.translations(from: job.requests))
            } catch {
                job.reply.resume(throwing: error)
            }
        }
    }

    /// The run is over. Ends the closure and takes the hidden view away; the next page through this
    /// pair finds it `.installed` and never comes back here.
    func release(_ pair: Pair) {
        doorbells[pair]?.finish()
        doorbells[pair] = nil
        armed[pair] = nil
    }

    func releaseAll() {
        for pair in armed.keys { release(pair) }
    }

    /// The store's backstop for the same thing: a run that failed, or was cancelled, or asked for a
    /// language the reader declined, must not leave a task mounted for the next one to queue behind.
    func finishedRun() {
        releaseAll()
    }

    // MARK: Names and failures

    /// The language as a person calls it, in their own language — Foundation already knows, so these
    /// never reach the string catalogue.
    nonisolated static func name(of language: Locale.Language) -> String {
        // The plain language code first, deliberately. `supportedLanguages` hands back maximal
        // identifiers — `ru-Cyrl-RU`, `en-Latn-SG` — and asking Foundation to name one of those
        // gives "русский (кириллица, Россия)", which is not what a menu or an error should say.
        if let code = language.languageCode?.identifier,
           let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }
        let identifier = language.maximalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// What this Mac can do *from* one language, by target. A menu cannot await, and asking for
    /// twenty-five pair statuses every time one opens would be twenty-five calls for a list that
    /// does not change while a page is open — so it is filled once per source language and read
    /// synchronously after.
    private(set) var statuses: [String: LanguageAvailability.Status] = [:]
    private var statusSource: String?

    func loadStatuses(from source: Locale.Language) async {
        let key = source.maximalIdentifier
        guard statusSource != key else { return }
        statusSource = key
        await loadLanguages()
        var found: [String: LanguageAvailability.Status] = [:]
        for language in languages {
            found[language.maximalIdentifier] = await availability.status(from: source, to: language)
        }
        guard statusSource == key else { return }       // another page overtook us
        statuses = found
    }

    /// `nil` while the answer has not been asked for yet — which is not the same as "no", and a
    /// menu that greys everything out until an await finishes is worse than one that briefly
    /// offers something it then refuses.
    func known(from source: Locale.Language, to target: Locale.Language) -> LanguageAvailability.Status? {
        guard statusSource == source.maximalIdentifier else { return nil }
        return statuses[target.maximalIdentifier]
    }

    /// The plain answer, so callers do not have to import `Translation` to ask a yes/no question.
    /// False while unknown, because "not asked yet" is not "no".
    func cannotTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        known(from: source, to: target) == .unsupported
    }

    /// The languages a menu can offer, once they have been asked for. `offeredLanguages` is async
    /// and a menu is not, so the view loads this on appear and reads it synchronously after.
    private(set) var languages: [Locale.Language] = []

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await offeredLanguages
    }

    /// `supportedLanguages` is a list of *locales* — `en-Latn-US`, `en-Latn-CA`, `en-Latn-SG` are
    /// three entries and one language. A picker wants languages, so it gets one per language code,
    /// sorted by what they are called here.
    var offeredLanguages: [Locale.Language] {
        get async {
            var seen = Set<String>()
            var out: [Locale.Language] = []
            for language in await availability.supportedLanguages {
                guard let code = language.languageCode?.identifier, seen.insert(code).inserted else { continue }
                out.append(language)
            }
            return out.sorted { Self.name(of: $0).localizedCaseInsensitiveCompare(Self.name(of: $1)) == .orderedAscending }
        }
    }

    /// `TranslationError`'s members are static constants matched with `~=`, not enum cases, so this
    /// is a `switch` over the error itself rather than over a case list.
    nonisolated private static func failure(
        _ error: any Error, source: Locale.Language, target: Locale.Language
    ) -> any Error {
        switch error {
        case is CancellationError:
            error
        case TranslationError.alreadyCancelled:
            CancellationError()
        case TranslationError.notInstalled:
            PageTranslationError.notInstalled(language: name(of: target))
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            PageTranslationError.unsupportedPair(source: name(of: source), target: name(of: target))
        default:
            PageTranslationError.engine("Apple Translation", error.localizedDescription)
        }
    }
}
#endif
