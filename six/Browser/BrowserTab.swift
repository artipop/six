import Foundation
import Observation
import WebKit

/// One tab — a `WebPage` (the new SwiftUI-native WebKit model object) bound to a profile.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: Profile.ID
    let page: WebPage
    /// A fresh window shows six's own start page instead of loading someone's home page. The first
    /// navigation replaces it for good.
    private(set) var showsStartPage = true
    /// A restored window doesn't load until it is first shown (or an agent looks at it): relaunching
    /// with a hundred windows must not fire a hundred requests. Until then this is its address.
    private(set) var pendingURL: URL?
    private var restoredTitle = ""
    /// Committed navigations go here (the profile's history); set by `BrowserState`.
    @ObservationIgnored var onNavigation: ((BrowserTab, NavigationOutcome) -> Void)?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?

    enum NavigationOutcome { case committed, finished }

    init(id: UUID = UUID(), profileID: Profile.ID, dataStore: WKWebsiteDataStore, restoring url: URL? = nil, title: String = "") {
        self.id = id
        self.profileID = profileID
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = "Six/1.0"
        self.page = WebPage(configuration: configuration, navigationDecider: TabNavigationDecider())
        if let url {
            showsStartPage = false
            pendingURL = url
            restoredTitle = title
        }
        navigationTask = Task { [weak self] in
            guard let page = self?.page else { return }
            do {
                for try await event in page.navigations {
                    guard let self else { return }
                    switch event {
                    case .committed: onNavigation?(self, .committed)
                    case .finished: onNavigation?(self, .finished)
                    default: break
                    }
                }
            } catch {}
        }
    }

    /// The tab is closing: stop the page and the navigation feed.
    func close() {
        navigationTask?.cancel()
        onNavigation = nil
        page.stopLoading()
    }

    var title: String {
        if showsStartPage { return "New Window" }
        if !page.title.isEmpty { return page.title }
        if !restoredTitle.isEmpty { return restoredTitle }
        return currentURL?.host() ?? "New Tab"
    }

    /// The page's URL, or the one a restored window is waiting to load.
    var currentURL: URL? { pendingURL ?? page.url }

    /// Loads a restored window's page. Called when the window comes on screen and by the tools.
    func resumeIfNeeded() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        _ = page.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        showsStartPage = false
        pendingURL = nil
        restoredTitle = ""
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
        return SearchEngine.current.searchURL(for: text)
    }

    /// Does this look like something to open rather than something to search for?
    static func looksLikeAddress(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return false }
        if let scheme = URL(string: text)?.scheme, ["http", "https", "file", "about"].contains(scheme) { return true }
        return text.contains(".") || text.hasPrefix("localhost")
    }
}
