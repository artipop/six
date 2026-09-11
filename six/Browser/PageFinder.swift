import Foundation
import Observation

/// What finding text on a page looks like from the outside: enough for a bar, and nothing that
/// belongs to one platform.
nonisolated struct TabFind: Sendable, Equatable {
    var query: String = ""
    /// Matches for `query`, and which one the bar and the page both point at — 1-based, so the bar
    /// can print "2 of 5" and 0 reads as "none" with no special case to write.
    var count = 0
    var current = 0
    /// The bar itself, apart from what it has found. A tab keeps its last query when the bar closes
    /// — Safari's own habit, and the reason this is a flag rather than the dictionary entry's mere
    /// presence — but stops drawing anything until ⌘F brings it back.
    var isActive = false

    var hasNoMatches: Bool { isActive && !query.isEmpty && count == 0 }
}

/// Find-on-page, one run per tab. Positions live here as what `FindScript` handed back — a count
/// and an index — never as the `Range`s themselves, which cannot cross out of the page's world at
/// all; `step` asks the page to move within the list it already built rather than send it over.
@Observable
final class PageFinder {
    private(set) var states: [UUID: TabFind] = [:]

    /// Which run of a search is the current one, the same guard `PageTranslator` keeps: a search
    /// fires on every keystroke, so a slow answer to an early one must not land after a faster
    /// answer to a later one has already redrawn the page.
    private var tokens: [UUID: Int] = [:]

    private func begin(_ id: UUID) -> Int {
        let token = (tokens[id] ?? 0) + 1
        tokens[id] = token
        return token
    }

    private func isCurrent(_ id: UUID, _ token: Int) -> Bool { tokens[id] == token }

    subscript(id: UUID) -> TabFind? { states[id] }

    /// ⌘F: bring the bar up, keeping whatever was last typed into it.
    func show(_ id: UUID) {
        var state = states[id] ?? TabFind()
        state.isActive = true
        states[id] = state
    }

    /// ⎋, or the bar's own close button. The highlights go with it; the query does not.
    func hide(_ page: some PageScriptRunner, id: UUID) {
        guard states[id]?.isActive == true else { return }
        states[id]?.isActive = false
        Task { _ = try? await page.runScript(FindScript.clear) }
    }

    func forget(_ id: UUID) {
        tokens[id] = (tokens[id] ?? 0) + 1 // whatever is still in flight is now stale
        states[id] = nil
    }

    /// Runs `query` against the page and lands on the first match.
    func search(_ query: String, in page: some PageScriptRunner, id: UUID) async {
        guard states[id] != nil else { return }
        states[id]?.query = query
        let token = begin(id)
        let found = await Self.run(FindScript.search, in: page, arguments: ["query": query])
        guard isCurrent(id, token) else { return }
        states[id]?.count = found.count
        states[id]?.current = found.current
    }

    /// ⏎ / ⇧⏎, or the bar's own arrows: the next match, or the previous, wrapping either way.
    func step(_ delta: Int, in page: some PageScriptRunner, id: UUID) async {
        guard let state = states[id], state.count > 0 else { return }
        let found = await Self.run(FindScript.step, in: page, arguments: ["delta": delta])
        states[id]?.current = found.current
    }

    private struct Found: Decodable { var count = 0; var current = 0 }

    private static func run(_ script: String, in page: some PageScriptRunner, arguments: [String: Any]) async -> Found {
        guard let value = try? await page.runScript(script, arguments: arguments),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return Found() }
        return (try? JSONDecoder().decode(Found.self, from: data)) ?? Found()
    }
}
