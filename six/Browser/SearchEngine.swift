import Foundation

/// Where a query goes, and where the start page gets its suggestions. Both engines answer suggestion
/// requests in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one parser serves both.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        }
    }

    private static let key = "six.searchEngine"

    static var current: SearchEngine {
        get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .duckDuckGo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    func suggestionsURL(for query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/ac/")!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "list")]
        case .google:
            components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            components.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }
}
