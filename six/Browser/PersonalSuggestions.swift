import Foundation
import Observation

/// The half of the search field that is about *you*: the query, embedded and put to the bookmark
/// index, so what you saved is offered before what an engine guesses.
///
/// `SearchSuggestions` is the other half, and the difference between them is the whole point. Those
/// completions are what everybody else is typing, fetched from a service that now knows what you
/// are typing. These are yours: the pages you kept, matched by *meaning* through the same
/// multilingual vectors the bookmarks window searches (`BookmarkStore.search`,
/// [docs/bookmarks.md](../../docs/bookmarks.md)) — so «плов» finds the English recipe you saved, and
/// "that thing about rate limits" finds the page whose title never said it. Nothing leaves the Mac:
/// the model runs on this GPU, the index is a table in `six.sqlite`.
///
/// Three rules keep it from being in the way:
///
/// - **It never wakes the model on its own.** With no bookmarks in scope there is nothing to search
///   and the query is dropped — a fresh install must not pull 470 MB of weights because somebody
///   typed in the field. Once there are bookmarks the model is already down: indexing needed it.
/// - **It waits longer than the engine does.** A keystroke costs a forward pass through E5 here, not
///   a request somebody else answers, so the debounce is 240 ms and the query in flight is cancelled
///   by the next one.
/// - **It would rather show nothing than something.** Vector search always answers — the nearest
///   thing is still the nearest thing when nothing is near — so a hit has to clear both `floor` and
///   `band`, or have the words in it literally. Two rows at most, above the engine's eight.
@MainActor
@Observable
final class PersonalSuggestions {
    /// The saved pages worth offering for what is being typed, best first.
    private(set) var hits: [BookmarkHit] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Longer than `SearchSuggestions.debounce` (140 ms), for the reason in the class comment.
    private static let debounce = Duration.milliseconds(240)
    /// Under this, a query is a prefix rather than a subject: "th" is about nothing.
    private static let minimumQuery = 3
    private static let limit = 2
    /// How close the *best* passage has to be before any row is worth showing — **and it depends on
    /// how much was typed**, which is the whole of what these two numbers know.
    ///
    /// `SIX_PERSONAL_SELFTEST` over three saved pages, one query per line (the score is
    /// `1 − cosine distance`, against the same page every time — an English Wikipedia article about
    /// pilaf):
    ///
    /// | typed | best | | typed | best |
    /// |---|---|---|---|---|
    /// | плов | **0.843** | | руд | 0.821 |
    /// | рецепт | **0.841** | | рудник | 0.823 |
    /// | pilaf | **0.907** | | рудники урала | 0.812 |
    /// | рецепт риса с бараниной | **0.811** | | пло | 0.819 |
    /// | | | | асд | 0.813 |
    ///
    /// The left column is what the page is about. The right column is a word about mines, a fragment
    /// of one, and three letters mashed on the keyboard — and *«асд» scores 0.813*, between a real
    /// query about mines and a real query about a recipe. A single absolute cutoff cannot tell those
    /// apart, and the reason is not subtle: the score carries an offset that has nothing to do with
    /// the subject. A Cyrillic anything leans toward the page whose text has Cyrillic in it, a long
    /// document has more passages and so more chances to hold one near anything, and a query gets
    /// *lower* as words are added to it — «рецепт» 0.841, «рецепт риса с бараниной» 0.811, both about
    /// the page they found.
    ///
    /// So the floor moves with the query instead:
    ///
    /// - **One word: 0.83.** A lone word being typed is a prefix until proven otherwise, and every
    ///   fragment measured above lands at 0.81–0.823 while every real single word lands at 0.84 and
    ///   up. This is the rule that stops «руд» from offering a recipe.
    /// - **More than one: 0.80.** Words dilute the score, so the same bar would throw away the
    ///   questions that are most clearly questions.
    ///
    /// `band` is the second rule, and it is not about the score at all: the rows after the first have
    /// to be within this of the best, so a runner-up rides along only when it is nearly as close —
    /// what happens when two saved pages really are about one thing, and not what happens when the
    /// index is scraping. At 0.05 the runner-up came along every time, a different subject each time.
    ///
    /// Both are measured, not reasoned, and neither travels: re-run `SIX_PERSONAL_SELFTEST="one; two"`
    /// against a real library before moving either.
    private static let wordFloor = 0.83
    private static let phraseFloor = 0.80
    private static let band = 0.02

    /// Searches for `input`, or clears the rows when there is nothing to search.
    ///
    /// - Parameters:
    ///   - store: the bookmarks, which own the index and the embedder.
    ///   - scope: this profile's saved pages or every profile's — the same setting the bookmarks
    ///     window, the assistant and the agents read (`SettingsStore.bookmarkScope`).
    ///   - profileID: whose window is asking.
    func update(for input: String, in store: BookmarkStore, scope: BookmarkScope, profileID: Profile.ID) {
        task?.cancel()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address is not a question. Somebody typing `apple.com` wants the site, and embedding a
        // host is a forward pass spent on nothing.
        guard query.count >= Self.minimumQuery, !URL.looksLikeAddress(query) else {
            hits = []
            return
        }
        guard store.count(in: scope, profileID: profileID) > 0 else {
            hits = []
            return
        }
        task = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let found = await store.search(query, in: scope, profileID: profileID, limit: Self.limit * 4)
            guard !Task.isCancelled else { return }
            let words = query.split(whereSeparator: \.isWhitespace)
            let floor = words.count > 1 ? Self.phraseFloor : Self.wordFloor
            let terms = words.map { $0.lowercased() }.filter { $0.count >= 3 }
            // A page with every word of the query in its title, address or excerpt is offered
            // whatever the vectors think: the words being *there* is its own evidence, and a flat
            // 0.7 is all `BookmarkStore.search` gives a text match.
            let literal = found.filter { Self.containsEveryWord($0.bookmark, terms) }
            var near: [BookmarkHit] = []
            if let best = found.first, best.score >= floor {
                near = found.filter { $0.score >= best.score - Self.band }
            }
            var seen: Set<Bookmark.ID> = []
            hits = (literal + near)
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.score > $1.score }
                .prefix(Self.limit)
                .map { $0 }
        }
    }

    func clear() {
        task?.cancel()
        hits = []
    }

    /// The same test `BookmarkStore.search` makes for its text pass, asked again here because the
    /// score it hands a text match (a flat 0.7) doesn't say which of the two found it.
    private static func containsEveryWord(_ bookmark: Bookmark, _ terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let haystack = (bookmark.title + " " + bookmark.url.absoluteString + " " + bookmark.excerpt).lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}
