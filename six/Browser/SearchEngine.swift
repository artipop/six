import Foundation

/// Where a query goes, and where the start page gets its suggestions. Both engines answer suggestion
/// requests in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one parser serves both.
nonisolated enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        }
    }

    /// The engine in settings — one value for the address bar, every start page and the tools.
    @MainActor static var current: SearchEngine {
        get { SettingsStore.shared?.searchEngine ?? .duckDuckGo }
        set { SettingsStore.shared?.searchEngine = newValue }
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

    /// The query behind one of this engine's results pages, if `url` is one — so history can show
    /// "паша · DuckDuckGo Search" instead of the results page's title.
    func query(from url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems,
              let raw = items.first(where: { $0.name == "q" })?.value else { return nil }
        let q = Self.decoded(raw)
        guard !q.isEmpty else { return nil }
        switch self {
        case .duckDuckGo: return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") ? q : nil
        case .google: return host.hasPrefix("www.google.") && url.path() == "/search" ? q : nil
        }
    }

    /// A query string's space, however the page that wrote it spelled one.
    ///
    /// six writes `%20`; both engines write `+` in the address their own search box produces, and
    /// `URLComponents` decodes the escapes without touching the `+` — which is how history came to
    /// show "слово+раз". Substituting before the decode rather than after is what keeps a
    /// searched-for plus, which arrives as `%2B`, a plus.
    private static func decoded(_ percentEncoded: String) -> String {
        let spaced = percentEncoded.replacingOccurrences(of: "+", with: "%20")
        return spaced.removingPercentEncoding ?? percentEncoded
    }

    /// Whichever engine's results page this is.
    static func search(from url: URL) -> (engine: SearchEngine, query: String)? {
        for engine in allCases {
            if let query = engine.query(from: url) { return (engine, query) }
        }
        return nil
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

// MARK: - Settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// The engine six searches with. Read statically through `SearchEngine.current`.
    var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: self[.searchEngine] ?? "") ?? .duckDuckGo }
        set { self[.searchEngine] = newValue.rawValue }
    }
}
