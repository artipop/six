import Foundation
import WebKit

/// Search results for an agent, fetched the way the browser would fetch them: a `WebPage` of its own,
/// off screen, with no window and no profile behind it.
///
/// The source is DuckDuckGo's HTML endpoint — the no-JavaScript version of the result page, whose
/// markup (`.result__a`, `.result__snippet`) has been stable for years and needs no API key. When it
/// answers with nothing (a challenge page, a layout change) the full result page is tried next, and
/// what comes back from either is a list, not a page to read: the agent picks the ones worth opening
/// as real windows.
@MainActor
final class WebSearch {
    nonisolated struct Result: Sendable {
        var title: String
        var url: URL
        var snippet: String
    }

    /// One place results can come from: where to ask, and how to read the answer.
    private struct Source {
        var url: (String) -> URL?
        var script: String
    }

    /// Kept between calls: the page holds the connection and the (ephemeral) cookie jar, and a search
    /// is usually followed by another one.
    private lazy var page: WebPage = {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = UserAgent.applicationName
        return WebPage(configuration: configuration)
    }()

    func search(_ query: String, limit: Int) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserTool.Failure(message: "query is required") }
        for source in Self.sources {
            guard let url = source.url(trimmed) else { continue }
            let rows = await load(url, script: source.script)
            let results = Self.results(from: rows, limit: limit)
            if !results.isEmpty { return results }
        }
        return []
    }

    private func load(_ url: URL, script: String) async -> [[String: Any]] {
        var request = URLRequest(url: url)
        // Search engines answer in the language the browser asks for, and an agent looking for tickets
        // from Novosibirsk wants the sites a person here would get.
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        _ = page.load(request)
        await withLoading()
        return (try? await page.callJavaScript(script)) as? [[String: Any]] ?? []
    }

    /// Bounded: an agent waits for this, and a hanging search must not become a hanging turn.
    private func withLoading(timeout: TimeInterval = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while page.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func results(from rows: [[String: Any]], limit: Int) -> [Result] {
        var seen = Set<String>()
        var results: [Result] = []
        for row in rows {
            guard let href = row["url"] as? String, let url = URL(string: href), let host = url.host() else { continue }
            guard !Self.engineHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { continue }
            guard seen.insert(href).inserted else { continue }
            let title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (row["snippet"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(Result(title: title.isEmpty ? host : title, url: url, snippet: snippet))
            if results.count >= limit { break }
        }
        return results
    }

    private static let engineHosts = ["duckduckgo.com", "html.duckduckgo.com", "lite.duckduckgo.com"]

    private static var acceptLanguage: String {
        let languages = Locale.preferredLanguages.prefix(3)
        guard !languages.isEmpty else { return "en" }
        return languages.enumerated()
            .map { index, code in index == 0 ? code : "\(code);q=\(String(format: "%.1f", 1 - Double(index) * 0.2))" }
            .joined(separator: ",")
    }

    private static let sources: [Source] = [
        // The no-JavaScript result page: a list of `.result` blocks, each with a link and a snippet.
        // Its hrefs go through DuckDuckGo's redirector, which carries the real one in `uddg`.
        Source(
            url: { query in
                var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
                components.queryItems = [URLQueryItem(name: "q", value: query)]
                return components.url
            },
            script: """
                const unwrap = (href) => {
                    try {
                        const url = new URL(href, location.href);
                        return url.searchParams.get('uddg') || url.href;
                    } catch (e) { return href; }
                };
                return Array.from(document.querySelectorAll('.result')).map(result => {
                    const link = result.querySelector('a.result__a');
                    const snippet = result.querySelector('.result__snippet');
                    if (!link) return null;
                    return {
                        title: link.innerText.trim().replace(/\\s+/g, ' '),
                        url: unwrap(link.getAttribute('href')),
                        snippet: snippet ? snippet.innerText.trim().replace(/\\s+/g, ' ') : ''
                    };
                }).filter(Boolean);
                """
        ),
        // The ordinary result page, in case the plain one turns us away. Result titles are the only
        // stable landmark: take the link around each one and the text of the block it sits in.
        Source(
            url: { query in
                var components = URLComponents(string: "https://duckduckgo.com/")!
                components.queryItems = [URLQueryItem(name: "q", value: query)]
                return components.url
            },
            script: """
                const results = Array.from(document.querySelectorAll('[data-testid="result"], article'));
                return results.map(result => {
                    const link = result.querySelector('a[href^="http"]');
                    const heading = result.querySelector('h2, h3');
                    if (!link) return null;
                    const text = result.innerText.trim().replace(/\\s+/g, ' ');
                    const title = (heading ? heading.innerText : link.innerText).trim().replace(/\\s+/g, ' ');
                    return { title: title, url: link.href, snippet: text.slice(0, 300) };
                }).filter(Boolean);
                """
        ),
    ]
}
