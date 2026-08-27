#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
import WebKit

/// What a column holds: a web page, or a document — Markdown the user (or an agent) writes, with a
/// `WebPage` of its own for the rendered preview. The layout does not care which.
enum TabContent {
    case web
    case document(TextDocument)
}

/// One tab — a `WebPage` (the new SwiftUI-native WebKit model object) bound to a profile, or a
/// document window (see `TabContent`).
///
/// The page is **not** owned for the window's lifetime. It is built the first time the window is
/// shown (or the first time anything asks to talk to it) and given back when the app is over its
/// live-page budget — see `LivePageCache` for the policy and `discard()` for what survives it. A
/// window with no live page is not a lesser window: it has its address, its title, its history, its
/// scroll offset and a picture of itself, which is everything needed to put the same page back.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: Profile.ID
    let content: TabContent
    /// The profile's store, kept so the page can be built again after a discard. Documents render in
    /// a non-persistent store instead: nothing a preview renders is anyone's site data.
    @ObservationIgnored private let dataStore: WKWebsiteDataStore?
    /// The app-wide budget this window's page counts against; set by `BrowserState`.
    @ObservationIgnored weak var cache: LivePageCache?
    /// Where the window's picture is kept between launches; set by `BrowserState`.
    @ObservationIgnored weak var thumbnails: PageThumbnails?
    /// Ad and tracker blocking. The window has a content controller of its own (see
    /// `ContentBlocker`), so what is attached follows the address this window is showing; set by
    /// `BrowserState`.
    @ObservationIgnored weak var blocker: ContentBlocker?
    /// Extensions: the profile's controller goes into the page's configuration, which is what makes
    /// this window visible to them at all. Nil for a private profile, which runs none.
    @ObservationIgnored weak var extensions: ExtensionStore?
    /// This window's `WKUserContentController` — the blocker's rules and the devtools hooks live in
    /// it; set by `BrowserState`.
    @ObservationIgnored weak var pageControllers: PageControllers?
    /// Console and network capture, and whether the page is inspectable; set by `BrowserState`.
    @ObservationIgnored weak var devTools: DevToolsStore?
    /// What sites were allowed to use the camera, the microphone and the motion sensors. The page's
    /// `deviceSensorAuthorization` is this window's question routed here; set by `BrowserState`.
    @ObservationIgnored weak var permissions: SitePermissions?

    /// The live page, when there is one. Read it to *draw* the window; anything that needs to talk to
    /// the page uses `page`, which builds one.
    private(set) var livePage: WebPage?
    /// Bumped for every page built. `WebView` is identified by it, so a rebuilt page gets a fresh
    /// view instead of the old one quietly pointing at a new model.
    private(set) var generation = 0
    var hasLivePage: Bool { livePage != nil }

    /// The page, built on demand — and a window that was waiting to load starts loading.
    ///
    /// Everything that talks to the page goes through here: the tools, the assistant, highlights,
    /// export. Everything that only *describes* the window deliberately does not (`title`,
    /// `currentURL`, `isLoading`, `canGoBack`…), or the address bar alone would be enough to keep
    /// every window in the strip live.
    var page: WebPage {
        let page = materialize()
        cache?.touch(id)
        resumeIfNeeded()
        return page
    }

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
    /// A restored — or discarded — window doesn't load until it is first shown (or an agent looks at
    /// it): relaunching with a hundred windows must not fire a hundred requests. Until then this is
    /// its address.
    private(set) var pendingURL: URL?
    /// What the window knows about itself with no page to ask: kept up to date while there is one.
    private var savedTitle = ""
    private var savedURL: URL?
    /// Back and forward across a discard. WebKit's own lists belong to the page and go with it, so
    /// the window keeps the addresses and walks them itself once a rebuilt page runs out of its own.
    @ObservationIgnored private var savedBack: [URL] = []
    @ObservationIgnored private var savedForward: [URL] = []
    /// Where the page was scrolled to, put back when a discarded window loads again.
    @ObservationIgnored private var savedScroll: Double = 0
    @ObservationIgnored private var pendingScroll: Double?
    /// The page as it last looked. Stands in for it in the strip and while a rebuilt page loads, so
    /// coming back to a discarded window shows the page rather than a white rectangle.
    private(set) var thumbnail: PlatformImage?
    @ObservationIgnored private var lastThumbnailAt = Date.distantPast
    @ObservationIgnored private var loadStartedAt = Date.distantPast
    /// Lets go of the picture — the oldest ones do, so a long strip's cards are not a memory leak of
    /// their own (`LivePageCache.notePicture`). The file stays: this is memory, not the picture.
    func forgetPicture() {
        thumbnail = nil
    }

    /// Reads the window's picture back — from an earlier launch, or from before the memory budget let
    /// go of it. Called when the overview is about to draw the window as a card.
    func loadPictureIfNeeded() {
        guard thumbnail == nil, let thumbnails else { return }
        Task {
            guard let image = await thumbnails.read(id), self.thumbnail == nil else { return }
            LivePageCache.log("read the picture of \(self.title) off disk")
            self.thumbnail = image
            self.cache?.notePicture(self)
        }
    }

    /// The size the strip last drew this window at, for the thumbnail.
    @ObservationIgnored var displaySize: CGSize = CGSize(width: 900, height: 700)

    /// Web Inspector, turned on or off while the window is open.
    func applyInspectable(_ isInspectable: Bool) {
        livePage?.isInspectable = isInspectable
    }

    // MARK: The camera and the microphone

    /// What this window's page is doing with the devices right now. `WebPage` publishes both, so the
    /// title bar's indicator follows the page without polling it — and reads `livePage`, never
    /// `page`, so drawing a title bar never builds one.
    var cameraCapture: WKMediaCaptureState { livePage?.cameraCaptureState ?? .none }
    var microphoneCapture: WKMediaCaptureState { livePage?.microphoneCaptureState ?? .none }
    var isCapturing: Bool { cameraCapture != .none || microphoneCapture != .none }
    /// Muted only counts while something is actually on: a window using nothing is not a quiet one.
    var isCaptureMuted: Bool {
        isCapturing && cameraCapture != .active && microphoneCapture != .active
    }

    /// The mute switch behind the indicator. Muted is not stopped — the call stays up and the page
    /// knows it was muted, which is what a call expects when you press the button in the toolbar.
    func setCaptureMuted(_ muted: Bool) {
        guard let page = livePage else { return }
        let state: WKMediaCaptureState = muted ? .muted : .active
        Task {
            if page.cameraCaptureState != .none { await page.setCameraCaptureState(state) }
            if page.microphoneCaptureState != .none { await page.setMicrophoneCaptureState(state) }
        }
    }

    /// Takes a device away for good. Blocking a site that is already looking through the camera has
    /// to close the shutter now; an answer that only applies to the next call is not an answer.
    func stopCapture(_ permission: SitePermission) {
        guard let page = livePage else { return }
        Task {
            switch permission {
            case .camera: await page.setCameraCaptureState(.none)
            case .microphone: await page.setMicrophoneCaptureState(.none)
            case .motion: break
            }
        }
    }

    /// Set by `HighlightStore` when a stored passage could not be found on the page again.
    var highlightNote: String?
    /// Committed navigations go here (the profile's history); set by `BrowserState`.
    @ObservationIgnored var onNavigation: ((BrowserTab, NavigationOutcome) -> Void)?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?

    enum NavigationOutcome { case committed, finished }

    init(id: UUID = UUID(), profileID: Profile.ID, dataStore: WKWebsiteDataStore, restoring url: URL? = nil, title: String = "") {
        self.id = id
        self.profileID = profileID
        self.dataStore = dataStore
        self.content = .web
        if let url {
            showsStartPage = false
            pendingURL = url
            savedTitle = title
        }
    }

    /// A document window. Its preview page is non-persistent: nothing it renders is anyone's site data.
    init(id: UUID = UUID(), profileID: Profile.ID, document: TextDocument) {
        self.id = id
        self.profileID = profileID
        self.dataStore = nil
        self.content = .document(document)
        showsStartPage = false
    }

    // MARK: Building and discarding the page

    /// Builds the page if this window has none. Cheap to call: the second call hands back the first's.
    @discardableResult
    private func materialize() -> WebPage {
        if let livePage { return livePage }
        let started = LivePageCache.debugging ? ContinuousClock.now : nil
        defer { if let started { LivePageCache.log("built \(title) in \(started.duration(to: .now))") } }
        var configuration = WebPage.Configuration()
        let page: WebPage
        if isDocument {
            configuration.websiteDataStore = .nonPersistent()
            // A preview renders Markdown six itself wrote out; there is no site here to grant
            // anything to, so the question is answered before it can be asked.
            configuration.deviceSensorAuthorization = .init(decision: .deny)
            let decider = DocumentNavigationDecider()
            decider.onLink = { [weak self] url in
                guard let self else { return }
                self.onDocumentLink?(self, url)
            }
            page = WebPage(configuration: configuration, navigationDecider: decider)
            page.isInspectable = devTools?.isInspectable ?? false
        } else {
            configuration.websiteDataStore = dataStore ?? .nonPersistent()
            configuration.applicationNameForUserAgent = UserAgent.applicationName
            // The blocker is told where the window is going before its controller is built: the
            // controller is configured on creation, and what it gets depends on the address.
            blocker?.note(id, showing: pendingURL ?? savedURL)
            if let controller = pageControllers?.controller(for: id) {
                configuration.userContentController = controller
            }
            configuration.webExtensionController = extensions?.controller(for: profileID)
            let decider = TabNavigationDecider()
            // Before the load, not after: a site on the allowlist must never have the rules applied
            // to it in the first place, and one that isn't must have them from its first request.
            decider.onNavigate = { [weak self] url in
                guard let self else { return }
                self.blocker?.note(self.id, showing: url)
            }
            // The page suspends inside this closure while the bar is up, which is the whole point:
            // WebKit's own answer (`.prompt`) puts up a popover six can neither remember nor undo.
            let windowID = id
            let profileID = profileID
            let permissions = permissions
            configuration.deviceSensorAuthorization = .init { [weak permissions] permission, _, origin in
                guard let permissions else { return .deny }
                return await permissions.decide(permission, origin: origin,
                                                in: windowID, profileID: profileID)
            }
            page = WebPage(configuration: configuration, navigationDecider: decider,
                           dialogPresenter: PageDialogs())
        }
        livePage = page
        generation += 1
        watchNavigations(of: page)
        cache?.noteLive(self)
        return page
    }

    /// Is there any work behind showing this window — a page to build, an address waiting to load? A
    /// window that is ready costs nothing to show, and the focus can be moved through it for free.
    var needsBuilding: Bool {
        guard !showsStartPage else { return false }
        return livePage == nil || pendingURL != nil
    }

    /// The window is coming on screen: it needs a page, and if it was waiting to load, it loads.
    ///
    /// A window still on the start page is the exception — six's start page is SwiftUI, and building a
    /// page for it would spend a web content process on a text field.
    func prepareForDisplay() {
        guard !showsStartPage else { return }
        materialize()
        resumeIfNeeded()
    }

    /// Gives the page back to the system. The window keeps its address, title, history stacks, scroll
    /// offset and thumbnail, and builds the same page again the next time it is shown — which is what
    /// makes this discarding rather than closing. Called by `LivePageCache`, never by the views.
    func discard() {
        guard let page = livePage else { return }
        savedTitle = title
        savedURL = page.url ?? savedURL
        savedBack += page.backForwardList.backList.map(\.url)
        savedForward = page.backForwardList.forwardList.map(\.url) + savedForward
        // A document is never waiting on an address: its preview is rendered from the text again by
        // `DocumentView` as soon as the column is back on screen.
        if !showsStartPage, !isDocument, let url = page.url { pendingURL = url }
        navigationTask?.cancel()
        navigationTask = nil
        // A question belongs to the page that asked it. This one is going.
        permissions?.forget(id)
        page.stopLoading()
        livePage = nil
        generation += 1
        // Nothing asynchronous here on purpose: an `await` on the way out means something is holding
        // the page while it waits, and a page that is held is a page that was not given back. The
        // scroll offset and the picture were taken while the window was still on screen
        // (`rememberViewState`), which is also the only time they can be taken at all.
    }

    /// The tab is closing: stop the page and the navigation feed for good.
    func close() {
        navigationTask?.cancel()
        onNavigation = nil
        onDocumentLink = nil
        permissions?.forget(id)
        livePage?.stopLoading()
        livePage = nil
        thumbnail = nil
        cache?.forget(id)
        thumbnails?.remove(id)
    }

    private func watchNavigations(of page: WebPage) {
        navigationTask = Task { [weak self] in
            do {
                for try await event in page.navigations {
                    guard let self else { return }
                    switch event {
                    case .committed:
                        savedURL = page.url ?? savedURL
                        // Redirects and history moves never go through the decider.
                        blocker?.note(id, showing: page.url)
                        extensions?.noteChanged(self, [.URL, .loading])
                        // What was captured belonged to the page being left.
                        devTools?.noteNavigation(id)
                        onNavigation?(self, .committed)
                    case .finished:
                        savedURL = page.url ?? savedURL
                        savedTitle = page.title
                        extensions?.noteChanged(self, [.title, .loading])
                        restoreScrollIfNeeded(page)
                        onNavigation?(self, .finished)
                        // Only to give a window that has never been drawn something to show. The
                        // picture that matters is taken when it leaves the screen; taking one after
                        // every load would be the most frequent trigger and the least useful one,
                        // since a page that just loaded is a page you are looking at.
                        if thumbnail == nil { rememberViewState(force: true) }
                    default: break
                    }
                }
            } catch {}
        }
    }

    // MARK: What the window knows without a page

    var title: String {
        if let document { return document.title }
        if showsStartPage { return String(localized: "New Window") }
        if let live = livePage, !live.title.isEmpty { return live.title }
        if !savedTitle.isEmpty { return savedTitle }
        return currentURL?.host() ?? "New Tab"
    }

    /// The page's URL, the one a waiting window will load, or the last one it had. A document has none.
    var currentURL: URL? {
        guard !isDocument else { return nil }
        if let pendingURL { return pendingURL }
        return livePage?.url ?? savedURL
    }

    var isLoading: Bool { livePage?.isLoading ?? false }
    var estimatedProgress: Double { livePage?.estimatedProgress ?? 0 }

    var canGoBack: Bool { !(livePage?.backForwardList.backList.isEmpty ?? true) || !savedBack.isEmpty }
    var canGoForward: Bool { !(livePage?.backForwardList.forwardList.isEmpty ?? true) || !savedForward.isEmpty }

    /// Back through the live page's own list first; when that runs out (a rebuilt page starts with an
    /// empty one) the window walks the addresses it kept across the discard.
    func goBack() {
        if let item = livePage?.backForwardList.backList.last {
            _ = livePage?.load(item)
            return
        }
        guard let url = savedBack.popLast() else { return }
        if let current = currentURL { savedForward.insert(current, at: 0) }
        load(url)
    }

    func goForward() {
        if let item = livePage?.backForwardList.forwardList.first {
            _ = livePage?.load(item)
            return
        }
        guard !savedForward.isEmpty else { return }
        let url = savedForward.removeFirst()
        if let current = currentURL { savedBack.append(current) }
        load(url)
    }

    func reloadOrStop() {
        if isLoading {
            livePage?.stopLoading()
        } else {
            _ = page.reload()
        }
    }

    // MARK: Loading

    /// Loads a waiting window's page — a restored one, or one whose page was discarded. Called when
    /// the window comes on screen and by the tools.
    func resumeIfNeeded() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        let page = materialize()
        pendingScroll = savedScroll > 0 ? savedScroll : nil
        loadStartedAt = Date()
        _ = page.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        guard !isDocument else { return }
        showsStartPage = false
        pendingURL = nil
        savedTitle = ""
        savedURL = url
        pendingScroll = nil
        savedScroll = 0
        loadStartedAt = Date()
        _ = page.load(URLRequest(url: url))
    }

    func navigate(to input: String) {
        guard let url = URL.fromUserInput(input) else { return }
        load(url)
    }

    private func restoreScrollIfNeeded(_ page: WebPage) {
        guard let offset = pendingScroll else { return }
        pendingScroll = nil
        Task {
            _ = try? await page.six("window.scrollTo(0, offset)", arguments: ["offset": offset])
        }
    }

    // MARK: Eviction guards and the thumbnail

    /// Is the page playing something? A page with sound or video is not an eviction candidate.
    var isPlayingMedia: Bool {
        get async {
            guard let livePage else { return false }
            return await livePage.mediaPlaybackState() == .playing
        }
    }

    /// Loading long enough that finishing it is worth protecting. Plenty of pages never stop loading
    /// at all — a tracker holding a connection open leaves `isLoading` true for good — so the guard
    /// has to expire, or those windows are the only ones that never give their memory back.
    var isLoadingRecently: Bool {
        isLoading && Date().timeIntervalSince(loadStartedAt) < 20
    }

    /// Is there something in the page the user typed and would lose?
    ///
    /// Deliberately narrow: a draft in a `textarea` and a filled-in password, nothing else. The
    /// obvious test — a field whose value differs from its attribute — calls every search box on the
    /// web unsent input, because a results page puts the query back in the box, and then the windows
    /// people actually browse with are the ones that can never be discarded.
    var hasUserInput: Bool {
        get async {
            guard let livePage, !isDocument else { return false }
            let script = """
            var drafts = Array.from(document.querySelectorAll('textarea')).some(function (element) {
                return element.value.trim().length > 20;
            });
            var secrets = Array.from(document.querySelectorAll('input[type=password]')).some(function (element) {
                return element.value !== '';
            });
            return drafts || secrets
            """
            return (try? await livePage.six(script)) as? Bool ?? false
        }
    }

    /// Takes what the window will need if its page is discarded — where the page is scrolled to, and
    /// a picture of it — while the page is still on screen, which is the only time either can be had:
    /// an unmounted web view has nothing to draw and a discarded one has nobody left to ask.
    ///
    /// Best effort and rate limited: it costs a round trip to the web content process, and a slightly
    /// stale picture is worth more than none.
    func rememberViewState(force: Bool = false) {
        guard let page = livePage, !showsStartPage, !page.isLoading else { return }
        guard force || Date().timeIntervalSince(lastThumbnailAt) > 3 else { return }
        lastThumbnailAt = Date()
        let region = CGRect(origin: .zero, size: displaySize)
        Task {
            if let offset = (try? await page.six("return window.scrollY")) as? Double {
                self.savedScroll = offset
            }
        }
        Task {
            // `afterScreenUpdates: false` takes what is already rendered: a window on its way off the
            // strip will never get another screen update, and waiting for one returns nothing.
            // 400 pt wide: a card is never drawn bigger than a column, and in the overview it is drawn
            // at a fraction of one. Every point here is a megabyte over a strip's worth of windows.
            let configuration = WebPage.ExportedContentConfiguration.image(
                region: .rect(region), snapshotWidth: 400, afterScreenUpdates: false)
            let clock = ContinuousClock()
            let started = clock.now
            guard let data = try? await page.exported(as: configuration),
                  let image = PlatformImage(data: data), image.size.width > 1 else {
                LivePageCache.log("no picture of \(self.title)")
                return
            }
            LivePageCache.log("drew \(self.title) at \(Int(image.size.width))×\(Int(image.size.height)), \(data.count / 1024) KB, in \(started.duration(to: clock.now))")
            self.thumbnail = image
            self.cache?.notePicture(self)
            self.thumbnails?.write(data, for: self.id)
        }
    }
}

/// Keeps navigation inside the tab; opens `target=_blank` links in the same page.
@MainActor
private final class TabNavigationDecider: WebPage.NavigationDeciding {
    /// Where the window is going, told before the request leaves — the one moment early enough to
    /// decide whether this page is blocked (`ContentBlocker`).
    var onNavigate: ((URL) -> Void)?

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if action.request.url?.scheme?.hasPrefix("http") == true, let url = action.request.url {
            onNavigate?(url)
        }
        return .allow
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
