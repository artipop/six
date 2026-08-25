import Foundation
import Observation

/// Completions for what is being typed on the start page. Every keystroke cancels the request in
/// flight and starts a new one after a short pause, so a fast typist makes one request, not ten.
///
/// The query leaves the machine as it is typed — that is what a suggestion service is — so it goes
/// out over an ephemeral session: no cookies, no cache, nothing tied to a profile.
@MainActor
@Observable
final class SearchSuggestions {
    private(set) var items: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private static let debounce = Duration.milliseconds(140)
    private static let limit = 8

    func update(for input: String) {
        task?.cancel()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            items = []
            return
        }
        let engine = SearchEngine.current
        task = Task { [session] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let fetched = await Self.fetch(query, from: engine, using: session)
            guard !Task.isCancelled else { return }
            items = Array(fetched.prefix(Self.limit))
        }
    }

    func clear() {
        task?.cancel()
        items = []
    }

    private nonisolated static func fetch(_ query: String, from engine: SearchEngine, using session: URLSession) async -> [String] {
        guard let url = engine.suggestionsURL(for: query) else { return [] }
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        guard json.count > 1, let suggestions = json[1] as? [String] else { return [] }
        return suggestions
    }
}
