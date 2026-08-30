import Foundation

/// The vocabulary of the translator, and nothing that belongs to one platform.
///
/// `Translation.framework` is Apple's, and six has a WebKitGTK front already and an Android one
/// planned ([linux.md](../../docs/linux.md), [android.md](../../docs/android.md)). So the engine is
/// a *seam*, next to the four in [storage.md](../../docs/storage.md) — Apple translates on device
/// with `TranslationSession`, Linux would with Bergamot's marian models (what Firefox uses offline),
/// Android with ML Kit. What must not happen is the portable half being trapped on the Apple side,
/// and the portable half is most of it: the JavaScript, the chunking, the state machine. This file
/// is the contract all four fronts read, so it imports `Foundation` and stops there.
///
/// `SitePermissions` is the shape being followed — the decision is shared, only the type the request
/// arrives as differs.

// MARK: - Text

/// One run of page text on its way to being other text. The id is the page's; an engine only ever
/// carries it back untouched.
nonisolated struct TranslationSegment: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var text: String
}

/// What one call to an engine may carry. Apple takes a real batch; a small on-device model does not.
nonisolated struct TranslationBatchLimits: Sendable {
    var segments: Int
    var characters: Int
}

// MARK: - Engines

/// Where a page's words go to be turned into other words — and the seam a second translator
/// plugs into.
///
/// One conformer today, `AppleTranslator`. The seam is not speculative all the same: Linux has no
/// `Translation.framework` and would use Bergamot's marian models, Android would use ML Kit, and
/// anyone wanting a keyed API translator writes a third conformer without touching the page walk,
/// the batching or the state machine above it.
///
/// **What deliberately does not go behind here is a language model.** Translating a page with one
/// is the wrong shape three times over: a single Wikipedia article is roughly 14k input and 8k
/// output tokens, which is real money per page against a local translator that is free; a thousand
/// segments through a network in batches is minutes against seconds; and a model that quietly
/// merges or drops a line leaves a page that looks translated and is wrong. Where a model *is* the
/// right answer — a passage that needs nuance, a language pair Apple does not have — the way in is
/// the agent, not this: `get_selection` hands the selected text to ⌘K and to MCP clients, and the
/// model translates it in the conversation where the reader can see what it did.
///
/// Deliberately not `Sendable`, and deliberately `@MainActor`: the project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and Apple's `TranslationSession` is a plain class
/// with no `Sendable` and no isolation of its own. Holding one in a main-actor store is fine; the
/// first `actor` or `Task.detached` wrapped around it stops compiling.
@MainActor
protocol PageTranslating: AnyObject {
    /// For the sentence a person reads when something goes wrong: "Apple Translation", "Claude Opus 5".
    /// A product name, so it is not localized — the same line `localization.md` draws for engines.
    var name: String { get }

    /// How much this engine wants at a time. The caller cuts the page up with
    /// `TranslationBatch.chunks` and hands over one batch at a time, so a torn-down run loses one
    /// batch rather than a page, and so progress can be shown at all.
    var limits: TranslationBatchLimits { get }

    /// Does this engine know this pair at all? Asked once per run, before any text is sent.
    func canTranslate(from source: Locale.Language, to target: Locale.Language) async -> Bool

    /// id → translation. An id may be missing from the result, and the caller then leaves that
    /// segment in its own language: a page 90 % translated is a usable page. Throws only when the
    /// whole batch failed.
    func translate(
        _ segments: [TranslationSegment],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [Int: String]

    /// True while the platform is fetching what it needs before a single word can be translated.
    ///
    /// There is no progress to report — `Translation.framework` offers `status(from:to:)`,
    /// `isReady` and `canRequestDownloads`, and no byte count anywhere — so this is a flag and not
    /// a fraction. Saying "downloading" is still the whole difference between a bar that looks
    /// stuck at zero and one that is honest about what it is waiting for.
    var isFetchingLanguages: Bool { get }

    /// The run is over — successfully, or not. An engine holding anything on the run's behalf lets
    /// it go here. Called exactly once per run, including when the run threw.
    func finishedRun()

    /// Stop whatever is in flight. Called on navigation — without it, leaving a three-thousand
    /// segment page keeps the engine grinding for a minute on text nobody will see.
    func cancel()
}

// MARK: - Running a script in the page

/// The one thing the state machine needs from a web engine: run this function body in the browser's
/// own world and hand back what it returned.
///
/// On Apple this is `WebPage.six(_:arguments:)` in a line. On Linux it is
/// `webkit_web_view_call_async_javascript_function`, which `SixGtk.WebKitView` does not expose yet —
/// and will have to for highlights and the readable-page extractor too, so it is not a cost this
/// feature invents.
@MainActor
protocol PageScriptRunner: AnyObject {
    func runScript(_ functionBody: String, arguments: [String: Any]) async throws -> Any?
}

extension PageScriptRunner {
    func runScript(_ functionBody: String) async throws -> Any? {
        try await runScript(functionBody, arguments: [:])
    }
}

// MARK: - Failure

nonisolated enum PageTranslationError: LocalizedError, Equatable {
    /// The page is a PDF, or its text is drawn on a canvas. Carries the sentence to show.
    case unsupportedPage(String)
    /// Neither engine knows this pair.
    case unsupportedPair(source: String, target: String)
    /// The pair exists but its language pack is not on this machine, and the user declined to get it.
    case notInstalled(language: String)
    /// The session was taken away mid-batch — the window closed, or the view carrying it was rebuilt.
    case interrupted
    /// Anything the engine itself reported.
    case engine(String, String)

    var errorDescription: String? {
        #if os(Linux)
        // `String(localized:)` and the strings catalog behind it are Apple Foundation's; a GTK front
        // localises through gettext, so these are the keys and it translates them itself.
        switch self {
        case .unsupportedPage(let why):
            why
        case .unsupportedPair(let source, let target):
            "There is no translation from \(source) to \(target)"
        case .notInstalled(let language):
            "\(language) has not been downloaded"
        case .interrupted:
            "The translation was interrupted"
        case .engine(let name, let message):
            "\(name) could not translate this page: \(message)"
        }
        #else
        switch self {
        case .unsupportedPage(let why):
            why
        case .unsupportedPair(let source, let target):
            String(localized: "There is no translation from \(source) to \(target)")
        case .notInstalled(let language):
            String(localized: "\(language) has not been downloaded. Add it in System Settings › General › Language & Region › Translation Languages.")
        case .interrupted:
            String(localized: "The translation was interrupted")
        case .engine(let name, let message):
            String(localized: "\(name) could not translate this page: \(message)")
        }
        #endif
    }
}
