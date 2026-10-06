import Foundation
import Observation

/// What finding text on a page looks like from the outside: enough for a bar, and nothing that
/// belongs to one platform.
nonisolated struct TabFind: Sendable, Equatable {
    var query: String = ""
    /// Whether the engine found `query`. It says no more than that: there is no "2 of 5".
    var isFound = false
    /// The bar itself, apart from what it has found. A tab keeps its last query when the bar closes
    /// — Safari's own habit, and the reason this is a flag rather than the dictionary entry's mere
    /// presence — but stops drawing anything until ⌘F brings it back.
    var isActive = false

    var hasNoMatches: Bool { isActive && !query.isEmpty && !isFound }
}

/// Find-on-page, one run per tab, through the engine's own find: no script runs in the page, and
/// the engine selects the match and scrolls to it (docs/page-scripts.md).
@Observable
final class PageFinder {
    private(set) var states: [UUID: TabFind] = [:]

    /// The engine's find — tab, query, backwards → found. Wired by the front at launch.
    @ObservationIgnored var find: (@MainActor (UUID, String, Bool) async -> Bool)?

    /// Which run of a search is the current one, the same guard `PageTranslator` keeps: a search
    /// fires on every keystroke, so a slow answer to an early one must not land after a faster
    /// answer to a later one has already redrawn the page.
    private var tokens: [UUID: Int] = [:]

    private func begin(_ id: UUID) -> Int {
        let token = (tokens[id] ?? 0) + 1
        tokens[id] = token
        return token
    }

    subscript(id: UUID) -> TabFind? { states[id] }

    /// ⌘F: bring the bar up, keeping whatever was last typed into it.
    func show(_ id: UUID) {
        var state = states[id] ?? TabFind()
        state.isActive = true
        states[id] = state
    }

    /// ⎋, or the bar's own close button. The query stays.
    func hide(_ id: UUID) {
        states[id]?.isActive = false
    }

    func forget(_ id: UUID) {
        tokens[id] = (tokens[id] ?? 0) + 1 // whatever is still in flight is now stale
        states[id] = nil
    }

    /// Looks for `query` in the page and lands on a match.
    func search(_ query: String, id: UUID) async {
        guard states[id] != nil else { return }
        states[id]?.query = query
        let token = begin(id)
        let found = query.isEmpty ? false : await find?(id, query, false) ?? false
        guard tokens[id] == token else { return }
        states[id]?.isFound = found
    }

    /// ⏎ / ⇧⏎, or the bar's own arrows: the next match, or the previous, wrapping either way.
    func step(_ delta: Int, id: UUID) async {
        guard let state = states[id], state.isFound else { return }
        _ = await find?(id, state.query, delta < 0)
    }
}
