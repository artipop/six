import Foundation
import Observation
import WebKit

/// What a column holds: a web page, or a document — Markdown the user (or an agent) writes, with a
/// `WebPage` of its own for the rendered preview. The layout does not care which.
enum TabContent {
    case web(WebPage)
    case document(TextDocument)
}

/// One tab — a `WebPage` (the new SwiftUI-native WebKit model object) bound to a profile, or a
/// document window (see `TabContent`).
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: Profile.ID
    let content: TabContent
    /// The web page — or, for a document, the page that renders its preview (and exports it).
    let page: WebPage
    /// The document, when this window is one.
    var document: TextDocument? {
        if case .document(let document) = content { return document }
        return nil
    }
    var isDocument: Bool { document != nil }
    /// A link clicked in a document's preview: the document's own page never navigates away, the
    /// browser opens (or focuses) a window for the URL instead. Set by `BrowserState`.
    @ObservationIgnored var onDocumentLink: ((BrowserTab, URL) -> Void)?
    /// A fresh window shows six's own start page instead of loading someone's home page. The first
    /// navigation replaces it for good.
    private(set) var showsStartPage = true
    /// A restored window doesn't load until it is first shown (or an agent looks at it): relaunching
    /// with a hundred windows must not fire a hundred requests. Until then this is its address.
    private(set) var pendingURL: URL?
    private var restoredTitle = ""
    /// Set by `HighlightStore` when a stored passage could not be found on the page again.
    var highlightNote: String?
    /// Committed navigations go here (the profile's history); set by `BrowserState`.
    @ObservationIgnored var onNavigation: ((BrowserTab, NavigationOutcome) -> Void)?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?

    enum NavigationOutcome { case committed, finished }

    init(id: UUID = UUID(), profileID: Profile.ID, dataStore: WKWebsiteDataStore, restoring url: URL? = nil, title: String = "") {
        self.id = id
        self.profileID = profileID
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = UserAgent.applicationName
        let page = WebPage(configuration: configuration, navigationDecider: TabNavigationDecider())
        self.page = page
        self.content = .web(page)
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

    /// A document window. Its preview page is non-persistent: nothing it renders is anyone's site data.
    init(id: UUID = UUID(), profileID: Profile.ID, document: TextDocument) {
        self.id = id
        self.profileID = profileID
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let decider = DocumentNavigationDecider()
        self.page = WebPage(configuration: configuration, navigationDecider: decider)
        self.content = .document(document)
        showsStartPage = false
        decider.onLink = { [weak self] url in
            guard let self else { return }
            self.onDocumentLink?(self, url)
        }
    }

    /// The tab is closing: stop the page and the navigation feed.
    func close() {
        navigationTask?.cancel()
        onNavigation = nil
        onDocumentLink = nil
        page.stopLoading()
    }

    var title: String {
        if let document { return document.title }
        if showsStartPage { return "New Window" }
        if !page.title.isEmpty { return page.title }
        if !restoredTitle.isEmpty { return restoredTitle }
        return currentURL?.host() ?? "New Tab"
    }

    /// The page's URL, or the one a restored window is waiting to load. A document has none.
    var currentURL: URL? {
        guard !isDocument else { return nil }
        return pendingURL ?? page.url
    }

    /// Loads a restored window's page. Called when the window comes on screen and by the tools.
    func resumeIfNeeded() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        _ = page.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        guard !isDocument else { return }
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

/// A document's preview only ever shows the document: `load(html:)` and in-page anchors go through,
/// a link to anywhere else is handed to the browser to open as a window.
@MainActor
private final class DocumentNavigationDecider: WebPage.NavigationDeciding {
    var onLink: ((URL) -> Void)?

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if url.scheme == "about" || url.scheme == "six" { return .allow }
        onLink?(url)
        return .cancel
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
