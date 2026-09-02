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
    /// How close the *best* passage has to be before any row is worth showing.
    /// - **And what it is not: a measure of relevance.** `SIX_PERSONAL_SELFTEST` over three saved
    ///   pages, one query per line (the scores are `1 − cosine distance`):
    ///
    ///   | query | best | runner-up |
    ///   |---|---|---|
    ///   | плов → *Pilaf* | 0.843 | 0.768 |
    ///   | рецепт риса с бараниной → *Pilaf* | 0.811 | 0.755 |
    ///   | rate limiting → *Rate limiting* | 0.922 | 0.800 |
    ///   | data race → *data-race safety* | 0.848 | 0.812 |
    ///   | погода в москве завтра → nothing saved | 0.767 | 0.744 |
    ///   | купить билеты в тбилиси → nothing saved | 0.811 | 0.787 |
    ///
    ///   The ranking is right every time — the query about pilaf finds the English page about pilaf,
    ///   which is what the multilingual embedder is for — and the *number* is worth nothing across
    ///   queries: a question about nothing saved scores 0.811 against a recipe, exactly what a real
    ///   question about that recipe scores. E5-small compresses everything into a narrow band and
    ///   shifts the whole band per query.
    /// - So the cutoff is two rules, and neither one is the score alone. `floor`: the best hit must
    ///   clear it, or the field shows nothing rather than the nearest thing to a question about
    ///   nothing. `band`: the rows after the first have to be within this of the best, so a runner-up
    ///   rides along only when it is nearly as close — which is what happens when two saved pages
    ///   really are about the same thing, and not what happens when the index is scraping. 0.02 is
    ///   narrow on purpose: at 0.05 the runner-up in the table above came along every time, and it
    ///   was a different page about a different subject each time.
    /// - Re-tune with `SIX_PERSONAL_SELFTEST="one; two"` against a real library, which prints both
    ///   what the index answered and what survived this.
    private static let floor = 0.80
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
            let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }.filter { $0.count >= 3 }
            // A page with every word of the query in its title, address or excerpt is offered
            // whatever the vectors think: the words being *there* is its own evidence, and a flat
            // 0.7 is all `BookmarkStore.search` gives a text match.
            let literal = found.filter { Self.containsEveryWord($0.bookmark, terms) }
            var near: [BookmarkHit] = []
            if let best = found.first, best.score >= Self.floor {
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
