import Foundation
import Observation
import WebKit

/// One tab — a `WebPage` (the new SwiftUI-native WebKit model object) bound to a profile.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let profileID: Profile.ID
    let page: WebPage

    init(profileID: Profile.ID, dataStore: WKWebsiteDataStore) {
        self.profileID = profileID
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Six/1.0"
        self.page = WebPage(configuration: configuration, navigationDecider: TabNavigationDecider())
    }

    var title: String {
        if !page.title.isEmpty { return page.title }
        return page.url?.host() ?? "New Tab"
    }

    func load(_ url: URL) {
        _ = page.load(URLRequest(url: url))
    }

    func navigate(to input: String) {
        guard let url = URL.fromUserInput(input) else { return }
        load(url)
    }
}

/// Keeps navigation inside the tab; opens `target=_blank` links in the same page.
private struct TabNavigationDecider: WebPage.NavigationDeciding {
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        .allow
    }
}

extension URL {
    /// Turns address-bar input into a URL: scheme-less hosts get `https://`, everything else becomes a search.
    static func fromUserInput(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://\(text)") {
            return url
        }
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}
