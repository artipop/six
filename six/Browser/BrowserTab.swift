#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation
import Observation
// For `NavigationAction.modifierFlags`: WebKit declares it in its SwiftUI half, so reading the keys
// held during a click needs SwiftUI imported even here, in the model.
import SwiftUI
import WebKit

/// What a column holds: a web page; a document — Markdown the user (or an agent) writes, with a
/// `WebPage` of its own for the rendered preview; an MCP app — somebody else's HTML, served to a
/// `WebPage` under the policy its server declared (see `MCPAppSession`); or one of six's own pages.
/// The layout does not care which.
enum TabContent {
    case web
    case document(TextDocument)
    case app(MCPAppSession)
    /// An app window from a previous launch, not running: what it was, waiting to be asked again.
    case pendingApp(AppWindowSnapshot)
    case builtIn(BuiltInPage)
}

/// A page six draws itself, addressed like any other.
///
/// Not a sheet. A sheet belongs to the application and stops everything else; a browser's answer to
/// "show me a list of things" is a page — it goes in a column, it has an address, it can be left
/// open next to what it is about, and the rail already knows how to carry it. The start page is the
/// same idea without an address of its own. Settings is the case that makes the argument: reading
/// what a site is allowed while looking at the site is the whole point, and a sheet cannot.
nonisolated enum BuiltInPage: String, Codable, Sendable, CaseIterable {
    /// The MCP servers six is host to, and what they carry (`MCPAppsView`).
    case apps
    /// Everything that used to be a menu item nobody could find: what six searches with, what it
    /// blocks, what a site is allowed, what the assistant talks to (`SettingsPageView`).
    ///
    /// The Mac only. A page of settings is a Mac shape — a column standing beside the thing it is
    /// about — and the phone has one column and a menu of its own (`PhoneContentView`). A snapshot
    /// carrying a settings column onto a phone finds no case for the name and opens a web window,
    /// which is what `page(for:)` returning nil already meant.
    #if os(macOS)
    case settings
    /// The first launch's one question, and the layout in the act of being read (`WelcomePage`).
    /// The Mac only, like settings: the phone has no assistant surface for the question to be about.
    case welcome
    #endif

    var url: URL { URL(string: "six://\(rawValue)")! }

    var title: String {
        switch self {
        case .apps: String(localized: "MCP Apps")
        #if os(macOS)
        case .settings: String(localized: "Settings")
        case .welcome: String(localized: "Welcome")
        #endif
        }
    }

    /// The page an address means, when it means one.
    static func page(for url: URL) -> BuiltInPage? {
        guard url.scheme?.lowercased() == "six" else { return nil }
        // `six://apps` puts the name in the host; `six:apps` would put it in the path. Both read the
        // same to a person typing, so both are taken.
        let name = (url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        return BuiltInPage(rawValue: name)
    }
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
    /// What this window has selected, or a caret in; set by `BrowserState`.
    @ObservationIgnored weak var pageFocus: PageFocusStore?
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

    /// The running app, when this window is one.
    var app: MCPAppSession? {
        if case .app(let session) = content { return session }
        return nil
    }
    var isApp: Bool { app != nil }

    /// The app this window was before six was last quit, when it has not been run again yet.
    var pendingApp: AppWindowSnapshot? {
        if case .pendingApp(let saved) = content { return saved }
        return nil
    }

    /// One of six's own pages, when this window is one.
    var builtIn: BuiltInPage? {
        if case .builtIn(let page) = content { return page }
        return nil
    }
    /// A window showing the web: not a document, not an app, not one of six's own pages. What
    /// history, highlights, bookmarks and the page tools are all about.
    var isWebPage: Bool { !isDocument && !isApp && builtIn == nil && pendingApp == nil }
    /// A link clicked in a document's preview: the document's own page never navigates away, the
    /// browser opens (or focuses) a window for the URL instead. Set by `BrowserState`.
    @ObservationIgnored var onDocumentLink: ((BrowserTab, URL) -> Void)?
    /// `six://…` was typed or followed. Set by `BrowserState`, which shows the page.
    @ObservationIgnored var onBuiltInAddress: ((BrowserTab, BuiltInPage) -> Void)?
    /// The page asked for a second window — a ⌘-click, `target=_blank`, `window.open`. Set by
    /// `BrowserState`, which puts a column next to this one.
    @ObservationIgnored var onNewWindow: ((BrowserTab, URLRequest, Bool) -> Void)?
    /// A link to save rather than to show. Set by `BrowserState`, which hands it to `DownloadStore`.
    @ObservationIgnored var onDownload: ((BrowserTab, URLRequest, String?) -> Void)?
    /// A fresh window shows six's own start page instead of loading someone's home page. The first
    /// navigation replaces it for good.
    private(set) var showsStartPage = true
    /// The window a link was followed out of, when this one was opened to carry that link — a
    /// ⌘-click, `target=_blank`, Open Link in New Window — rather than by the user or a restore. Set
    /// by `BrowserState`, which reads it together with `hasCommitted` to take the window back if the
    /// link turns out to be a file, and to put the reader back where they clicked.
    @ObservationIgnored var openedFrom: BrowserTab.ID?
    /// Has anything ever been shown here? A window whose only navigation became a download never
    /// commits one, and has neither a page to show nor a page to go back to.
    private(set) var hasCommitted = false
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

    // MARK: Picture-in-picture

    /// Is this window's video in the floating player right now?
    ///
    /// Asked of the page every time rather than remembered here, because six is not the only one who
    /// can put it there: the button in WebKit's own media controls, a site's own button and `⌥⇧P` all
    /// end in the same place, and a flag six kept would be right only for the third. Nothing observes
    /// it, so nothing has to be told — the live-page budget asks at the moment it is about to evict,
    /// which is the moment the answer is used (`PagePictureInPicture`).
    var isInPictureInPicture: Bool {
        get async {
            guard let livePage else { return false }
            return await livePage.isInPictureInPicture
        }
    }

    /// In, or back out. A window with no page never builds one for this: picture-in-picture is
    /// something a page one is *watching* does, and there is nothing to watch in a card.
    func togglePictureInPicture() {
        guard let livePage else { return }
        Task { await livePage.togglePictureInPicture() }
    }

    /// Why the last navigation stopped, when it stopped — and nil the rest of the time, which is
    /// almost always. Set from the navigation feed, cleared by the next load.
    private(set) var loadFailure: LoadFailure?

    /// A load that did not happen, in the terms a person can act on: where it was going, what the
    /// system said, and — the case this was written for — whether six is carrying the certificate
    /// authority the site was signed by and has it switched off.
    nonisolated struct LoadFailure: Equatable, Sendable {
        let url: URL?
        let host: String
        let code: Int
        let message: String
        /// The bundle in `CertificateStore` that would have carried this site, when there is one.
        let offeredCertificateBundle: String?

        /// The errors that mean "the chain did not check out", as `CFNetwork` spells them. Not the
        /// same thing as *six has an answer to it* — `offeredCertificateBundle` is that — but it is
        /// what decides whether the page talks about certificates at all.
        var isCertificateProblem: Bool {
            [NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorSecureConnectionFailed].contains(code)
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

    /// An app window brought back from the snapshot. Nothing is connected and nothing has run: the
    /// column shows what it was until it is asked again.
    init(id: UUID = UUID(), profileID: Profile.ID, pendingApp: AppWindowSnapshot) {
        self.id = id
        self.profileID = profileID
        dataStore = nil
        content = .pendingApp(pendingApp)
        showsStartPage = false
    }

    /// One of six's own pages. Pure SwiftUI, like the start page: no `WebPage` is ever built for it,
    /// which is the point — a list of servers should not cost a web content process.
    init(id: UUID = UUID(), profileID: Profile.ID, builtIn: BuiltInPage) {
        self.id = id
        self.profileID = profileID
        dataStore = nil
        content = .builtIn(builtIn)
        showsStartPage = false
    }

    /// An app window. Like a document it belongs to a profile without borrowing its store: an app is
    /// served from six's own scheme and keeps nothing of anyone's site data.
    init(id: UUID = UUID(), profileID: Profile.ID, app: MCPAppSession) {
        self.id = id
        self.profileID = profileID
        dataStore = nil
        content = .app(app)
        showsStartPage = false
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
        } else if let app {
            // The app's own store is never anyone's: a non-persistent one, thrown away with the
            // window. Its two documents are served by `MCPAppSchemeHandler`, which is where the
            // Content-Security-Policy the server declared is actually applied.
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = app.contentController
            if let shell = URLScheme(MCPAppScheme.shell) { configuration.urlSchemeHandlers[shell] = app.schemeHandler }
            if let content = URLScheme(MCPAppScheme.content) { configuration.urlSchemeHandlers[content] = app.schemeHandler }
            // The camera and the microphone an app declared are still the profile's question to
            // answer, asked of the app's origin like any other.
            let windowID = id
            let profileID = profileID
            let permissions = permissions
            configuration.deviceSensorAuthorization = .init { [weak permissions] permission, _, origin in
                guard let permissions else { return .deny }
                return await permissions.decide(permission, origin: origin, in: windowID, profileID: profileID)
            }
            let decider = AppNavigationDecider()
            decider.onLink = { [weak self] url in
                guard let self else { return }
                self.onDocumentLink?(self, url)
            }
            page = WebPage(configuration: configuration, navigationDecider: decider)
            page.isInspectable = devTools?.isInspectable ?? false
            app.page = page
            _ = page.load(URLRequest(url: app.url))
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
            decider.onNewWindow = { [weak self] request, behind in
                guard let self else { return }
                self.onNewWindow?(self, request, behind)
            }
            decider.onDownload = { [weak self] request, suggestedName in
                guard let self else { return }
                self.onDownload?(self, request, suggestedName)
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
        // Every page WebKit builds has picture-in-picture off and no field in the configuration to
        // ask with, so it is asked for here, once, for every kind of window (`PagePictureInPicture`).
        page.allowPictureInPicture()
        // WebKit's fullscreen window cannot size a view SwiftUI holds by constraints, so the
        // hold is swapped for the duration (`PageElementFullscreen`). Measured on macOS and fixed
        // there only: the same page on iOS has no window to be moved into, and nobody has looked.
        #if os(macOS)
        page.watchElementFullscreenHosting()
        #endif
        generation += 1
        watchNavigations(of: page)
        cache?.noteLive(self)
        return page
    }

    /// Is there any work behind showing this window — a page to build, an address waiting to load? A
    /// window that is ready costs nothing to show, and the focus can be moved through it for free.
    var needsBuilding: Bool {
        guard !showsStartPage, builtIn == nil, pendingApp == nil else { return false }
        return livePage == nil || pendingURL != nil
    }

    /// The window is coming on screen: it needs a page, and if it was waiting to load, it loads.
    ///
    /// A window still on the start page is the exception — six's start page is SwiftUI, and building a
    /// page for it would spend a web content process on a text field.
    func prepareForDisplay() {
        guard !showsStartPage, builtIn == nil, pendingApp == nil else { return }
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
        if !showsStartPage, isWebPage, let url = page.url { pendingURL = url }
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
        onNewWindow = nil
        onDownload = nil
        permissions?.forget(id)
        livePage?.stopLoading()
        livePage = nil
        thumbnail = nil
        cache?.forget(id)
        thumbnails?.remove(id)
    }

    // MARK: What survives a move to another profile

    /// A window apart from the store its page was built against: where it has been, where it can go
    /// forward to, how far down it was, and how it last looked.
    ///
    /// A `WebPage`'s data store is fixed when the page is built and WebKit's back-forward list
    /// belongs to that page, so a window cannot be handed another profile's cookies. Moving one
    /// between profiles is therefore a rebuild (`BrowserState.moveTab(_:toProfile:)`), and this is
    /// everything the window built in its place is given: the three things a discard already keeps,
    /// plus the picture, which is still a picture of the same page.
    struct Trail {
        var back: [URL] = []
        var forward: [URL] = []
        var scroll: Double = 0
        var picture: PlatformImage?
    }

    /// The trail as it stands, the live page's own lists included — in the same order `discard()`
    /// joins them, the addresses kept across a discard first and the page's own after.
    var trail: Trail {
        Trail(back: savedBack + (livePage?.backForwardList.backList.map(\.url) ?? []),
              forward: (livePage?.backForwardList.forwardList.map(\.url) ?? []) + savedForward,
              scroll: savedScroll, picture: thumbnail)
    }

    /// Takes over from the window this one was built to replace. Called before it is first shown: the
    /// offset goes back into the page when the waiting address loads, as a discarded window's does.
    func adopt(_ trail: Trail) {
        savedBack = trail.back
        savedForward = trail.forward
        savedScroll = trail.scroll
        thumbnail = trail.picture
    }

    /// The window's one subscription to what its page is doing.
    ///
    /// `page.navigations` is a **throwing** sequence, and a load that fails throws through it. Read
    /// once, as a single `for try await`, the loop therefore ended at the first bad address — and
    /// the window stopped recording every navigation after it: no visit written to history, no
    /// title kept for the card, nothing told to the blocker, no scroll put back, and the capture
    /// from the previous page never cleared. Measured: a window sent to a site with an untrusted
    /// certificate and then to `example.com` left the second visit out of the database entirely.
    ///
    /// So the failure is written down and the feed is subscribed to again. Only a *navigation*
    /// failure is worth coming back from — a closed page and a dead web content process are the
    /// page itself ending, and re-subscribing to those would be a spin.
    private func watchNavigations(of page: WebPage) {
        navigationTask = Task { [weak self] in
            while !Task.isCancelled {
                let outcome = await Self.observe(page) { [weak self] event in
                    self?.apply(event, of: page)
                }
                guard let self, self.livePage === page, !Task.isCancelled else { return }
                guard case .failed(let error) = outcome else { return }
                self.noteFailure(error)
            }
        }
    }

    private enum FeedOutcome {
        /// The page is over: it was closed, or its content process died.
        case ended
        /// One navigation failed. The page is still there and will be asked to load again.
        case failed(any Error)
    }

    /// One pass over the feed, so the loop above reads as a loop. Nothing here touches the tab —
    /// the events go back through the closure, on the main actor, where the rest of the class lives.
    private static func observe(_ page: WebPage,
                                _ handle: (WebPage.NavigationEvent) -> Void) async -> FeedOutcome {
        do {
            for try await event in page.navigations {
                handle(event)
            }
            return .ended
        } catch {
            guard let navigation = error as? WebPage.NavigationError,
                  case .failedProvisionalNavigation(let reason) = navigation else { return .ended }
            return .failed(reason)
        }
    }

    /// What a failed load leaves behind: a sentence, and whether six has an answer to it.
    private func noteFailure(_ error: any Error) {
        let failure = error as NSError
        // Cancelled is not a failure. `stop()` looks like this, and so does the decider sending a
        // request somewhere else — a `target=_blank` link becoming a window of its own, a response
        // becoming a download — which is a navigation that succeeded elsewhere.
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        // WebKit's own word for the same thing, which is what a cancelled policy decision reports.
        if failure.domain == "WebKitErrorDomain", failure.code == 102 || failure.code == 101 { return }
        let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? currentURL
        let host = url?.host() ?? ""
        let offered = CertificateStore.shared?.offeredBundle(for: host)
        loadFailure = LoadFailure(url: url,
                                  host: host,
                                  code: failure.code,
                                  message: failure.localizedDescription,
                                  offeredCertificateBundle: offered?.id)
        // The offer goes into the line too. It is the one fact that decides what the window is
        // about to say, and reading it back is the only way to tell "six has no answer to this"
        // from "six had one and never looked".
        let offer = offered.map { " — six carries \($0.id), switched off" } ?? ""
        devTools?.noteLoadFailure(id,
                                  url: url?.absoluteString ?? "",
                                  reason: "\(failure.localizedDescription) (\(failure.domain) \(failure.code))\(offer)")
    }

    private func apply(_ event: WebPage.NavigationEvent, of page: WebPage) {
        guard livePage === page else { return }
        switch event {
        case .startedProvisionalNavigation:
            // The window is trying again, whatever it was showing before.
            loadFailure = nil
        case .committed:
            loadFailure = nil
            hasCommitted = true
            savedURL = page.url ?? savedURL
            // Redirects and history moves never go through the decider.
            blocker?.note(id, showing: page.url)
            extensions?.noteChanged(self, [.URL, .loading])
            // What was captured belonged to the page being left, and so did what was selected in it.
            devTools?.noteNavigation(id)
            pageFocus?.noteNavigation(id)
            onNavigation?(self, .committed)
        case .finished:
            savedURL = page.url ?? savedURL
            savedTitle = page.title
            extensions?.noteChanged(self, [.title, .loading])
            restoreScrollIfNeeded(page)
            onNavigation?(self, .finished)
            // Only to give a window that has never been drawn something to show. The picture that
            // matters is taken when it leaves the screen; taking one after every load would be the
            // most frequent trigger and the least useful one, since a page that just loaded is a
            // page you are looking at.
            if thumbnail == nil { rememberViewState(force: true) }
        default: break
        }
    }

    // MARK: What the window knows without a page

    var title: String {
        if let document { return document.title }
        if let app { return app.title }
        if let builtIn { return builtIn.title }
        if let pendingApp { return pendingApp.toolTitle }
        if showsStartPage { return String(localized: "New Window") }
        if let live = livePage, !live.title.isEmpty { return live.title }
        if !savedTitle.isEmpty { return savedTitle }
        return currentURL?.host() ?? "New Tab"
    }

    /// The page's URL, the one a waiting window will load, or the last one it had. A document has
    /// none, and neither has an app: `mcp-app://…` is an address nobody can type, revisit or bookmark.
    var currentURL: URL? {
        // Six's own pages have an address, and it is the one thing about them worth showing: it can
        // be typed, and it says what the window is.
        if let builtIn { return builtIn.url }
        guard isWebPage else { return nil }
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

    /// Is there anything here to fetch again? A document is rendered from text six is holding, six's
    /// own pages are drawn rather than loaded, and a start page has never been anywhere.
    var canReload: Bool { isWebPage && currentURL != nil }

    /// The guard is here rather than on the menu item, because a menu item cannot be greyed out on
    /// an answer that changes with every navigation and does not rebuild the menu (`ViewCommands`).
    /// `⌘R` on a document is a key with nothing to do, and does nothing — asking `page` for one
    /// would build a web view for a window that is text six is holding.
    func reload() {
        guard canReload else { return }
        _ = page.reload()
    }

    /// The reload that does not believe the cache — everything is asked of the network again.
    func reloadFromOrigin() {
        guard canReload else { return }
        _ = page.reload(fromOrigin: true)
    }

    func stop() { livePage?.stopLoading() }

    /// The address bar's one button, which has room for one verb at a time. The menu has room for
    /// both and lists them separately.
    func reloadOrStop() {
        if isLoading { stop() } else { reload() }
    }

    /// Ask for the address that failed again. Not `reload()`: a provisional navigation that never
    /// committed left the page on whatever it was showing before — usually nothing at all — and
    /// reloading *that* asks for the wrong thing, or for nothing.
    func retryFailedLoad() {
        guard let url = loadFailure?.url ?? currentURL else { return }
        loadFailure = nil
        load(url)
    }

    /// The one button on the failure page that is not a retry: switch on the authority six was
    /// carrying all along, and ask for the site again.
    ///
    /// It is the same switch as the one in `six://settings` ▸ Privacy ▸ Certificates and it is
    /// written down in the same place, so a person who says yes here can read it, and say no again,
    /// where every other trust decision lives.
    func trustOfferedCertificate() {
        guard let bundle = loadFailure?.offeredCertificateBundle else { return }
        CertificateStore.shared?.setEnabled(true, for: bundle)
        retryFailedLoad()
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
        // An address of six's own is not something WebKit can be asked to fetch: it is a page six
        // draws, so it becomes a window rather than a navigation.
        if let page = BuiltInPage.page(for: url) {
            onBuiltInAddress?(self, page)
            return
        }
        // A magnet link pasted into the address bar, or handed over by anything else that calls
        // this: the system's, not WebKit's. `load` would silently do nothing with it.
        if ExternalScheme.isExternal(url) {
            ExternalScheme.open(url)
            return
        }
        guard isWebPage else { return }
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
        // A person who pastes `magnet:?xt=…` into the address bar means the app that claims it. This
        // lives here and not in `fromUserInput`, which the assistant's and the agents' tools also
        // call: what six cannot show they get a search for, not the power to launch whatever app has
        // registered a scheme.
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), text.rangeOfCharacter(from: .whitespaces) == nil,
           ExternalScheme.isExternal(url), ExternalScheme.hasHandler(for: url) {
            ExternalScheme.open(url)
            return
        }
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
            // An app is unsaved work by definition — its whole state lives in a document six
            // cannot rebuild — so it is never the window the budget takes back.
            if isApp { return true }
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

/// Everything a page asks for that is not "load this here".
///
/// The SwiftUI WebKit API has no UI client and no download delegate. A page that asks for a second
/// window (`target=_blank`, `window.open`, a ⌘-click) and a link that asks to be saved
/// (`<a download>`, a response no page can show) reach a decider and nowhere else; left at `.allow`
/// they are handed on to a delegate that does not exist, and the click does nothing at all. So the
/// decider cancels them and gives the request back to the browser, which has a strip to put a window
/// in and a `DownloadStore` to give a file to.
///
/// The context menu's own Open Link in New Window and Download Linked File never come through here —
/// they go straight to those missing delegates, which is why six builds the menu itself
/// (`PageContextMenu`). [links.md](../../docs/links.md) has the whole map.
@MainActor
private final class TabNavigationDecider: WebPage.NavigationDeciding {
    /// Where the window is going, told before the request leaves — the one moment early enough to
    /// decide whether this page is blocked (`ContentBlocker`).
    var onNavigate: ((URL) -> Void)?
    /// A second window: the browser opens a column for it. The flag says the click asked for it
    /// *behind* — a ⌘-click, which everywhere else means a background tab.
    var onNewWindow: ((URLRequest, Bool) -> Void)?
    /// A file rather than a page.
    var onDownload: ((URLRequest, String?) -> Void)?

    /// The site's certificate could not be traced back to anything the system trusts.
    ///
    /// Left alone this is where a Russian bank's page stops: the chain is signed by an authority no
    /// Apple machine has ever heard of, and to WebKit that is indistinguishable from somebody
    /// standing in the middle. `CertificateStore` gets to answer with the anchors the user switched
    /// on — and with none switched on, which is the default, it hands the question straight back and
    /// WebKit's own error page is what appears. See `CertificateStore.decide(_:)`.
    ///
    /// Only the *page's* handshakes come through here. A subresource fetched by a `URLSession` of
    /// six's own — a download — asks `DownloadStore`'s delegate instead, which asks the same store.
    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let certificates = CertificateStore.shared else { return (.performDefaultHandling, nil) }
        return await certificates.decide(challenge)
    }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        LinkTrace.log("action \(url.absoluteString) target=\(action.target == nil ? "none" : "frame") type=\(action.navigationType.rawValue) button=\(action.buttonNumber) mods=\(action.modifierFlags.rawValue) cmd=\(action.modifierFlags.contains(.command)) download=\(action.shouldPerformDownload)")
        if action.shouldPerformDownload {
            onDownload?(action.request, nil)
            return .cancel
        }
        // Not the web at all — `magnet:`, `mailto:`, a scheme some app on this machine claimed.
        // WebKit will not load one and says nothing about it either, so `.allow` here is a link that
        // does nothing; the app that owns the scheme gets it instead. Before the new-window branch,
        // because a `target=_blank` magnet link wants the torrent client and not a blank column.
        if ExternalScheme.isExternal(url) {
            let opened = ExternalScheme.open(url)
            LinkTrace.log("external \(url.absoluteString) opened=\(opened)")
            return .cancel
        }
        // A ⌘-click asks for the link somewhere else rather than here. WebKit keeps its own record of
        // the keys that were held (`modifierFlags`, declared in its SwiftUI half and carrying
        // SwiftUI's `EventModifiers`), which is the honest signal — nothing here depends on what the
        // keyboard happens to be doing by the time this runs.
        //
        // The ⌘ is the only thing that can be read, and `buttonNumber` is not a second signal:
        // despite the name it is not a button at all. Every activation driven by the mouse reports 1
        // — left, middle, plain or modified — and everything else reports 0, so a middle click cannot
        // be told from an ordinary one. Reading it as "the middle button" made every plain click on
        // every link open a window of its own. Measured by clicking all three.
        //
        // ⇧ cannot be read either, because a shift-modified click never arrives: WebKit sends every
        // one of them — ⇧ alone and ⌘⇧ together — to the UI client, the seat this API has none of,
        // and they reach nothing at all.
        let behind = action.navigationType == .linkActivated && action.modifierFlags.contains(.command)
        // The other way: no target frame means the frame does not exist yet — `target=_blank`,
        // `window.open`. There is nobody to answer that but the browser.
        if action.target == nil || behind {
            onNewWindow?(action.request, behind)
            return .cancel
        }
        if url.scheme?.hasPrefix("http") == true { onNavigate?(url) }
        return .allow
    }

    /// What came back cannot be shown — a zip, a dmg, anything served as an attachment. A browser
    /// downloads it; `.allow` here would leave the window on a blank page.
    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        guard let url = response.response.url else { return .allow }
        let http = response.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let isAttachment = disposition.hasPrefix("attachment")
        guard !response.canShowMimeType || isAttachment else { return .allow }
        LinkTrace.log("response \(url.absoluteString) canShow=\(response.canShowMimeType) attachment=\(isAttachment)")
        onDownload?(URLRequest(url: url), response.response.suggestedFilename)
        return .cancel
    }
}

/// `SIX_LINKS_TRACE=1` narrates what the page asked for. Off, it costs the branch and nothing else.
enum LinkTrace {
    static let isOn = ProcessInfo.processInfo.environment["SIX_LINKS_TRACE"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard isOn else { return }
        Log.debug(.links, message())
    }
}

/// A document's preview only ever shows the document: `load(html:)` and in-page anchors go through,
/// a link to anywhere else is handed to the browser to open as a window.
@MainActor
/// An app never navigates: the shell and the app's frame are the only two documents this window
/// ever shows, and a link the app's HTML carries becomes a window of six's own — the same answer a
/// document's preview gives.
private final class AppNavigationDecider: WebPage.NavigationDeciding {
    var onLink: ((URL) -> Void)?

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        if url.scheme == MCPAppScheme.shell || url.scheme == MCPAppScheme.content || url.scheme == "about" {
            return .allow
        }
        onLink?(url)
        return .cancel
    }
}

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
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "file", "about", "six"].contains(scheme) {
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
        // `magnet:?xt=…` is an address on a machine with a torrent client and a search query on one
        // without — which is also what keeps «note: buy milk» out of the address row.
        if let url = URL(string: text), ExternalScheme.isExternal(url), ExternalScheme.hasHandler(for: url) { return true }
        return text.contains(".") || text.hasPrefix("localhost")
    }
}

extension WebPage {
    /// `load(_:)` returns a navigation, not a verdict; this says whether there was anything to load.
    @discardableResult
    func load(_ item: WebPage.BackForwardList.Item?) -> Bool {
        guard let item else { return false }
        _ = load(item)
        return true
    }
}
