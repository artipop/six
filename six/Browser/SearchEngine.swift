import Foundation

/// Where a query goes, and where the start page gets its suggestions. All four engines answer
/// suggestion requests in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one
/// parser serves them all.
nonisolated enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo
    case google
    case bing
    case yandex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .yandex: "Yandex"
        }
    }

    /// The engine in settings — one value for the address bar, every start page and the tools.
    @MainActor static var current: SearchEngine {
        get { SettingsStore.shared?.searchEngine ?? .duckDuckGo }
        set { SettingsStore.shared?.searchEngine = newValue }
    }

    /// What the engine calls the query in its own address. Three of them say `q`; Yandex says
    /// `text`, and both halves of this file — writing a search and reading one back — go through
    /// here rather than assuming.
    private var queryParameter: String {
        switch self {
        case .duckDuckGo, .google, .bing: "q"
        case .yandex: "text"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        case .yandex: components = URLComponents(string: "https://yandex.ru/search/")!
        }
        components.queryItems = [URLQueryItem(name: queryParameter, value: query)]
        return components.url
    }

    /// The query behind one of this engine's results pages, if `url` is one — so history can show
    /// "паша · DuckDuckGo Search" instead of the results page's title.
    func query(from url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems,
              let raw = items.first(where: { $0.name == queryParameter })?.value else { return nil }
        let q = Self.decoded(raw)
        guard !q.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch self {
        case .duckDuckGo: return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") ? q : nil
        case .google: return host.hasPrefix("www.google.") && url.path() == "/search" ? q : nil
        case .bing: return (bare == "bing.com" || bare.hasSuffix(".bing.com")) && url.path() == "/search" ? q : nil
        // Yandex answers from a country domain per visitor — .ru, .com, .com.tr, .kz — and from
        // ya.ru; the results path is /search/, with /search/touch/ for the phone.
        case .yandex: return (bare == "ya.ru" || bare.hasPrefix("yandex.")) && url.path().hasPrefix("/search") ? q : nil
        }
    }

    /// A query string's space, however the page that wrote it spelled one.
    ///
    /// six writes `%20`; the engines write `+` in the address their own search box produces, and
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
        case .bing:
            components = URLComponents(string: "https://www.bing.com/osjson.aspx")!
            components.queryItems = [URLQueryItem(name: "query", value: query)]
        case .yandex:
            components = URLComponents(string: "https://suggest.yandex.ru/suggest-ff.cgi")!
            components.queryItems = [URLQueryItem(name: "part", value: query)]
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
