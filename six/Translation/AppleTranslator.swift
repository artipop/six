#if canImport(Translation)
import Foundation
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
final class AppleTranslator: PageTranslating {
    nonisolated var name: String { "Apple Translation" }

    /// Apple's batch call takes a real batch. 60 keeps a torn-down run cheap and still amortises.
    nonisolated var limits: TranslationBatchLimits {
        TranslationBatchLimits(segments: 60, characters: 12_000)
    }

    private struct Pair: Hashable {
        let source: String
        let target: String
        init(_ source: Locale.Language, _ target: Locale.Language) {
            self.source = source.maximalIdentifier
            self.target = target.maximalIdentifier
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
        let session = try await session(from: source, to: target)

        // `clientIdentifier` is what makes this cheap: the framework carries our own id through and
        // hands it back, so nothing depends on the responses arriving in order.
        let requests = segments.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id))
        }

        running = session
        defer { running = nil }
        do {
            let responses = try await session.translations(from: requests)
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

    func cancel() {
        running?.cancel()
        running = nil
    }

    // MARK: Sessions

    private func session(from source: Locale.Language, to target: Locale.Language) async throws -> TranslationSession {
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
            // The pair exists, the model is not on this machine, and only the SwiftUI path can ask
            // for it. Until that lands, say so rather than failing obscurely.
            throw PageTranslationError.notInstalled(language: Self.name(of: target))
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
