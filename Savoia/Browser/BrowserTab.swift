import AppKit
import Foundation
import Observation
import WebKit

/// What a column holds: a web page; a document — Markdown the user (or an agent) writes, with a
/// web view of its own for the rendered preview; an MCP app — somebody else's HTML, served to a
/// web view under the policy its server declared (see `MCPAppSession`); or one of Savoia's own pages.
/// The layout does not care which.
enum TabContent {
    case web
    case document(TextDocument)
    case app(MCPAppSession)
    /// An app window from a previous launch, not running: what it was, waiting to be asked again.
    case pendingApp(AppWindowSnapshot)
    case builtIn(BuiltInPage)
}

/// A page Savoia draws itself, addressed like any other.
///
/// Not a sheet. A sheet belongs to the application and stops everything else; a browser's answer to
/// "show me a list of things" is a page — it goes in a column, it has an address, it can be left
/// open next to what it is about, and the row already knows how to carry it. The start page is the
/// same idea without an address of its own. Configuration is the case that makes the argument: reading
/// what a site is allowed while looking at the site is the whole point, and a sheet cannot.
nonisolated enum BuiltInPage: String, Codable, Sendable, CaseIterable {
    /// Everything that used to be a menu item nobody could find: what Savoia searches with, what it
    /// blocks, what a site is allowed, what the assistant talks to (`ConfigurationPageView`).
    ///
    /// The Mac only. A page of configuration is a Mac shape — a column standing beside the thing it
    /// is about — and the phone has one column and a menu of its own (`PhoneContentView`). A snapshot
    /// carrying a configuration column onto a phone finds no case for the name and opens a web
    /// window, which is what `page(for:)` returning nil already meant.
    #if os(macOS)
    case configuration
    /// The first launch's one question, and the layout in the act of being read (`WelcomePage`).
    /// The Mac only, like configuration: the phone has no assistant surface for the question to be
    /// about.
    case welcome
    /// Every conversation with an agent, as a tab rather than a list down the side of the window
    /// (`AgentChatsPage`): it opens beside what you are doing and leaves when you are done with it.
    case chats
    /// One conversation, `savoia://chat/<id>` — a window of its own, so two can stand side by side
    /// and one can stay open next to the page it is about (`AgentChatPage`).
    case chat
    #endif

    var url: URL { url(section: nil) }

    /// A page that is one window per section rather than one window turned to a section.
    var isPerSection: Bool {
        #if os(macOS)
        self == .chat
        #else
        false
        #endif
    }

    /// `savoia://configuration/assistant#agents` — the pane is a page under this one, and the tab
    /// inside it is an anchor on that page, which is what a `#` means everywhere else on the web.
    func url(section: String?) -> URL {
        guard let section, !section.isEmpty else { return URL(string: "savoia://\(rawValue)")! }
        var words = section.split(separator: "/", maxSplits: 1)
        let pane = words.removeFirst()
        let anchor = words.first.map { "#\($0)" } ?? ""
        return URL(string: "savoia://\(rawValue)/\(pane)\(anchor)") ?? url
    }

    var title: String {
        switch self {
        #if os(macOS)
        case .configuration: String(localized: "Configuration")
        case .welcome: String(localized: "Welcome")
        case .chats: String(localized: "Chats")
        case .chat: String(localized: "Chat")
        #endif
        }
    }

    /// The page an address means, when it means one.
    static func page(for url: URL) -> BuiltInPage? { parse(url)?.page }

    /// The page an address means and which part of it, when it means one.
    ///
    /// `savoia://configuration/assistant` puts the name in the host and the pane in the path;
    /// `savoia:configuration/assistant` puts both in the path. Both read the same to a person typing,
    /// so both are taken. The fragment, when there is one, is the tab inside that pane — and the
    /// two come back as one string, `assistant/agents`, because that is what the page holds.
    static func parse(_ url: URL) -> (page: BuiltInPage, section: String?)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "savoia" || scheme == "six" else { return nil }
        var words = url.path.split(separator: "/").map(String.init)
        let name: String
        if let host = url.host(), !host.isEmpty {
            name = host.lowercased()
        } else {
            guard !words.isEmpty else { return nil }
            name = words.removeFirst().lowercased()
        }
        guard let page = BuiltInPage(rawValue: name) else { return nil }
        let section = [words.first, url.fragment()].compactMap { $0 }.joined(separator: "/")
        return (page, section.isEmpty ? nil : section)
    }
}

/// One tab — a `WKWebView` of its own bound to a profile, or a document window (see `TabContent`).
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
    /// Opened for remote automation (`Automation`): driven by a program, and nothing of it is kept.
    @ObservationIgnored private(set) var isAutomated = false
    /// The profile's store, kept so the page can be built again after a discard. Documents render in
    /// a non-persistent store instead: nothing a preview renders is anyone's site data.
    @ObservationIgnored let dataStore: WKWebsiteDataStore?
    /// The app-wide budget this window's page counts against; set by `BrowserState`.
    @ObservationIgnored weak var cache: LivePageCache?
    /// Where the window's picture is kept between launches; set by `BrowserState`.
    @ObservationIgnored weak var thumbnails: PageThumbnails?
    /// The picture the *site* draws itself with, by host. Nil for a private profile; set by
    /// `BrowserState`.
    @ObservationIgnored weak var siteIcons: SiteIcons?
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
    /// The tools this window's page declares for agents (WebMCP); set by `BrowserState`.
    @ObservationIgnored weak var webMCP: WebMCPStore?
    /// What sites were allowed to use the camera and the microphone; set by `BrowserState`.
    @ObservationIgnored weak var permissions: SitePermissions?

    /// The live page, when there is one. Read it to *draw* the window; anything that needs to talk to
    /// the page uses `page`, which builds one.
    private(set) var livePage: WKWebView?
    /// Bumped for every page built, so a rebuilt page gets a fresh host.
    private(set) var generation = 0
    @ObservationIgnored private var pageDelegate: PageDelegate?
    #if os(macOS)
    @ObservationIgnored let dialogs = PendingDialogs()
    #endif
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// What the live page says of itself, copied as it changes: a view observes these, not the web view.
    private var liveURL: URL?
    private var liveTitle = ""
    private var liveIsLoading = false
    private var liveProgress = 0.0
    private var liveCanGoBack = false
    private var liveCanGoForward = false
    private(set) var cameraCapture = WKMediaCaptureState.none
    private(set) var microphoneCapture = WKMediaCaptureState.none
    var hasLivePage: Bool { livePage != nil }

    /// The page, built on demand — and a window that was waiting to load starts loading.
    ///
    /// Everything that talks to the page goes through here: the tools, the assistant, highlights,
    /// export. Everything that only *describes* the window deliberately does not (`title`,
    /// `currentURL`, `isLoading`, `canGoBack`…), or the address bar alone would be enough to keep
    /// every window in the strip live.
    var page: WKWebView {
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

    /// The app this window was before Savoia was last quit, when it has not been run again yet.
    var pendingApp: AppWindowSnapshot? {
        if case .pendingApp(let saved) = content { return saved }
        return nil
    }

    /// One of Savoia's own pages, when this window is one.
    /// Which part of a built-in page is being looked at, as the fragment of its address:
    /// `savoia://configuration/assistant#agents`. Savoia's own pages have one address each, so a person sent to
    /// the assistant's settings from the ⌘E line used to land on General and have to find their way
    /// — and the address bar said `savoia://configuration` either way, which is an address that cannot
    /// bring you back to where you were.
    var section: String?
    /// What one of Savoia's own pages calls itself when its kind's name is not enough — a chat's title.
    /// Set by the page.
    var pageTitle: String?

    var builtIn: BuiltInPage? {
        if case .builtIn(let page) = content { return page }
        return nil
    }
    /// A window showing the web: not a document, not an app, not one of Savoia's own pages. What
    /// history, highlights, bookmarks and the page tools are all about.
    var isWebPage: Bool { !isDocument && !isApp && builtIn == nil && pendingApp == nil }
    /// A link clicked in a document's preview: the document's own page never navigates away, the
    /// browser opens (or focuses) a window for the URL instead. Set by `BrowserState`.
    @ObservationIgnored var onDocumentLink: ((BrowserTab, URL) -> Void)?
    /// `savoia://…` was typed or followed. Set by `BrowserState`, which shows the page.
    @ObservationIgnored var onBuiltInAddress: ((BrowserTab, BuiltInPage, String?) -> Void)?
    /// The page's context menu, for the link under the pointer. Set by `BrowserState`.
    @ObservationIgnored var onContextMenu: ((BrowserTab, URL?) -> NSMenu?)?
    /// A ⌘-click: the link opens behind, by its address, in a tab next to this one. Set by `BrowserState`.
    @ObservationIgnored var onLinkBehind: ((BrowserTab, URLRequest) -> Void)?
    /// `window.open` or a plain `target=_blank`: the tab WebKit is to load into, built on the
    /// configuration it handed over. Set by `BrowserState`.
    @ObservationIgnored var onPageWindow: ((BrowserTab, WKWebViewConfiguration) -> WKWebView?)?
    /// `window.close()` in a tab a page opened. Set by `BrowserState`.
    @ObservationIgnored var onPageClose: ((BrowserTab) -> Void)?
    @ObservationIgnored private(set) var isOpenedByPage = false
    @ObservationIgnored private var openerConfiguration: WKWebViewConfiguration?
    /// The live page was built on an extension's configuration (`ExtensionStore.pageConfiguration`).
    @ObservationIgnored private var showsExtensionPage = false
    /// A link to save rather than to show. Set by `BrowserState`, which hands it to `DownloadStore`.
    @ObservationIgnored var onDownload: ((BrowserTab, URLRequest, String?) -> Void)?
    /// A fresh window shows Savoia's own start page instead of loading someone's home page. The first
    /// navigation replaces it for good.
    private(set) var showsStartPage = true
    /// The window a link was followed out of, when this one was opened to carry that link — a
    /// ⌘-click, `target=_blank`, Open Link in New Window — rather than by the user or a restore. Set
    /// by `BrowserState`, which reads it together with `hasCommitted` to take the window back if the
    /// link turns out to be a file, and to put the reader back where they clicked.
    @ObservationIgnored var openedFrom: BrowserTab.ID?
    /// When the tab was last in front, or opened; what `TabCleaner` measures a tab left behind by.
    @ObservationIgnored var seenAt = Date()
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
    /// Whether the page that went had anywhere to go, for a window waiting on its state.
    private var savedCanGoBack = false
    private var savedCanGoForward = false
    /// WebKit's session state of the page that went: its back-forward list, each entry with its scroll offset.
    @ObservationIgnored private var savedState: Data?
    /// A resumed load's media waits for a gesture (`MediaHold`) — in that load's document only. Lifted
    /// when the next navigation starts, once the held one has committed.
    private enum MediaHoldState { case loading, shown }
    @ObservationIgnored private var mediaHold: MediaHoldState?
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
    /// go of it. Called when the ⌃Tab ring is about to draw the tab as a card.
    func loadPictureIfNeeded() {
        // Not while the one on disk is of the shape the window used to be: `displaySize` threw the
        // one in memory away for that reason, and reading the same picture back off disk would undo
        // the throwing away. The redraw it scheduled writes the file too, and then this can read it.
        guard thumbnail == nil, !pictureIsStale, let thumbnails else { return }
        Task {
            guard let image = await thumbnails.read(id), self.thumbnail == nil else { return }
            LivePageCache.log("read the picture of \(self.title) off disk")
            self.thumbnail = image
            self.cache?.notePicture(self)
        }
    }

    /// The size this tab was last drawn at, which is the size its picture is taken at. A change of
    /// shape — two tabs put side by side — drops the picture and asks for another once the size has
    /// stopped moving.
    @ObservationIgnored private var drawnSize = CGSize(width: 900, height: 700)
    /// The picture in hand, and the one on disk, are of a shape this window no longer is.
    @ObservationIgnored private(set) var pictureIsStale = false
    @ObservationIgnored private var redrawTask: Task<Void, Never>?

    var displaySize: CGSize {
        get { drawnSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            let was = drawnSize
            drawnSize = newValue
            // Shape and not size: every tab is redrawn on every window resize, and a
            // column that is the same rectangle a little larger has a picture that still fits it.
            let before = was.width / was.height
            let after = newValue.width / newValue.height
            guard was.width > 1, abs(after - before) / max(before, after) > 0.08 else { return }
            forgetPicture()
            pictureIsStale = true
            redrawTask?.cancel()
            redrawTask = Task { @MainActor [weak self] in
                // One switch animation, like the live-page budget's own settle: the picture is worth
                // taking of the window where it came to rest.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                // The flag is cleared where the new picture lands, and not here: a window with no
                // live page has nothing to take one *from*, and clearing it would let the picture of
                // the old shape be read back off disk. Until then the card says the window's name,
                // which is at least true.
                self.rememberViewState(force: true)
            }
        }
    }

    #if os(macOS)
    var isInspected: Bool { livePage.map(WebInspector.isOpen(on:)) ?? false }

    func toggleInspector() {
        guard let livePage else { return }
        WebInspector.toggle(on: livePage)
    }
    #endif

    // MARK: The camera, the microphone and the screen

    /// Screen or window sharing, which `WKWebView` publishes only as SPI (`DisplayCapture`).
    var displayCapture: WKMediaCaptureState = .none
    var isCapturing: Bool { cameraCapture != .none || microphoneCapture != .none || displayCapture != .none }

    /// The devices the page holds right now, the screen first: in that order they show the most of
    /// you. A call holds two at once, and each gets a button of its own in the address field.
    var capturingDevices: [CaptureDevice] {
        CaptureDevice.allCases.filter { captureState(of: $0) != .none }
    }

    func captureState(of device: CaptureDevice) -> WKMediaCaptureState {
        switch device {
        case .screen: displayCapture
        case .camera: cameraCapture
        case .microphone: microphoneCapture
        }
    }

    /// The mute switch behind one device's button. Muted is not stopped — the call stays up and the
    /// page knows it was muted, which is what a call expects when you press the button in the
    /// toolbar. One device at a time, because turning the camera off and staying audible is the
    /// most ordinary thing to do in a call.
    func setCaptureMuted(_ muted: Bool, _ device: CaptureDevice) {
        guard let page = livePage, captureState(of: device) != .none else { return }
        let state: WKMediaCaptureState = muted ? .muted : .active
        switch device {
        case .screen:
            #if os(macOS)
            DisplayCapture.setState(state, on: page)
            #endif
        case .camera:
            Task { await page.setCameraCaptureState(state) }
        case .microphone:
            Task { await page.setMicrophoneCaptureState(state) }
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
            case .location, .notifications, .motion, .pageTools: break
            }
        }
    }

    enum CaptureDevice: CaseIterable {
        case screen, camera, microphone
    }

    // MARK: Picture-in-picture

    /// Is this window's video in the floating player right now?
    ///
    /// Asked of the page every time rather than remembered here, because Savoia is not the only one who
    /// can put it there: the button in WebKit's own media controls, a site's own button and `⌥⇧P` all
    /// end in the same place, and a flag Savoia kept would be right only for the third. Nothing observes
    /// it, so nothing has to be told — the live-page budget asks at the moment it is about to evict,
    /// which is the moment the answer is used (`PagePictureInPicture`).
    var isInPictureInPicture: Bool {
        get async {
            guard let livePage else { return false }
            return await livePage.isInPictureInPicture()
        }
    }

    /// In, or back out. A window with no page never builds one for this: picture-in-picture is
    /// something a page one is *watching* does, and there is nothing to watch in a card.
    func togglePictureInPicture() {
        guard let livePage else { return }
        Task { await livePage.togglePictureInPicture() }
    }

    /// Why the last navigation stopped, when it stopped — and nil the rest of the time, which is
    /// almost always. Set by the navigation delegate, cleared by the next load.
    private(set) var loadFailure: LoadFailure?

    /// A load that did not happen, in the terms a person can act on: where it was going, what the
    /// system said, and — the case this was written for — whether Savoia is carrying the certificate
    /// authority the site was signed by and has it switched off.
    nonisolated struct LoadFailure: Equatable, Sendable {
        let url: URL?
        let host: String
        let code: Int
        let message: String
        /// The bundle in `CertificateStore` that would have carried this site, when there is one.
        let offeredCertificateBundle: String?

        /// The errors that mean "the chain did not check out", as `CFNetwork` spells them. Not the
        /// same thing as *Savoia has an answer to it* — `offeredCertificateBundle` is that — but it is
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
    /// A navigation was asked for and has not ended; `isLoading` rises a tick after the asking.
    @ObservationIgnored private var awaitsNavigation = false
    /// The navigation under way is a page given back to the system loading again.
    @ObservationIgnored private(set) var isResuming = false
    @ObservationIgnored private var loadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    enum NavigationOutcome { case committed, finished }

    init(id: UUID = UUID(), profileID: Profile.ID, dataStore: WKWebsiteDataStore, restoring url: URL? = nil,
         title: String = "", automated: Bool = false) {
        self.id = id
        self.profileID = profileID
        self.dataStore = dataStore
        self.content = .web
        isAutomated = automated
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

    /// One of Savoia's own pages. Pure SwiftUI, like the start page: no web view is ever built for it,
    /// which is the point — a list of servers should not cost a web content process.
    init(id: UUID = UUID(), profileID: Profile.ID, builtIn: BuiltInPage) {
        self.id = id
        self.profileID = profileID
        dataStore = nil
        content = .builtIn(builtIn)
        showsStartPage = false
    }

    /// An app window. Like a document it belongs to a profile without borrowing its store: an app is
    /// served from Savoia's own scheme and keeps nothing of anyone's site data.
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
    private func materialize() -> WKWebView {
        if let livePage { return livePage }
        let started = LivePageCache.debugging ? ContinuousClock.now : nil
        defer { if let started { LivePageCache.log("built \(title) in \(started.duration(to: .now))") } }
        // An extension's own page loads only into a view built on that extension's configuration.
        let ofExtension = isWebPage ? (pendingURL ?? savedURL).flatMap { extensions?.pageConfiguration(for: $0, profileID: profileID) } : nil
        showsExtensionPage = ofExtension != nil
        // A window a page opened keeps its opener only on the configuration WebKit handed over.
        let configuration = openerConfiguration ?? ofExtension ?? WKWebViewConfiguration()
        openerConfiguration = nil
        let kind: PageDelegate.Kind
        if isDocument {
            kind = .document
            configuration.websiteDataStore = .nonPersistent()
        } else if let app {
            kind = .app
            // Never anyone's store. `MCPAppSchemeHandler` serves the two documents, under the policy the server declared.
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = app.contentController
            configuration.setURLSchemeHandler(app.schemeHandler, forURLScheme: MCPAppScheme.shell)
            configuration.setURLSchemeHandler(app.schemeHandler, forURLScheme: MCPAppScheme.content)
        } else if showsExtensionPage {
            kind = .web
        } else {
            kind = .web
            configuration.websiteDataStore = dataStore ?? .nonPersistent()
            configuration.applicationNameForUserAgent = UserAgent.applicationName
            // Before its controller is built: what the controller gets depends on the address.
            blocker?.note(id, showing: pendingURL ?? savedURL)
            if let controller = pageControllers?.controller(for: id) {
                configuration.userContentController = controller
            }
            configuration.preferences.isElementFullscreenEnabled = true
            #if os(macOS)
            if isAutomated {
                devTools?.automation.prepare(configuration)
            } else {
                configuration.webExtensionController = extensions?.controller(for: profileID)
            }
            #endif
        }
        #if os(macOS)
        WebInspector.allow(in: configuration)
        Geolocation.shared.serve(configuration)
        SiteNotifications.shared.serve(configuration)
        #endif
        #if os(macOS)
        let view = isAutomated ? AutomatedWebView.self : WKWebView.self
        #else
        let view = WKWebView.self
        #endif
        let page = view.init(frame: CGRect(origin: .zero, size: drawnSize), configuration: configuration)
        let delegate = PageDelegate(kind: kind, tab: self)
        page.navigationDelegate = delegate
        page.uiDelegate = delegate
        pageDelegate = delegate
        page.allowsBackForwardNavigationGestures = kind == .web
        livePage = page
        observe(page)
        #if os(macOS)
        WebViewResponder.shared.register(page, for: id)
        page.allowPictureInPicture()
        DisplayCapture.observe(page) { [weak self] in self?.displayCapture = $0 }
        siteIcons?.watch(page)
        #endif
        if let app {
            app.page = page
            page.load(URLRequest(url: app.url))
        }
        generation += 1
        cache?.noteLive(self)
        return page
    }

    /// `WKWebView` is key-value observable and not `@Observable`.
    private func observe(_ page: WKWebView) {
        func watch<Value>(_ path: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
            page.observe(path) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.readPage() }
            }
        }
        observations = [watch(\.url), watch(\.title), watch(\.isLoading), watch(\.estimatedProgress),
                        watch(\.canGoBack), watch(\.canGoForward),
                        watch(\.cameraCaptureState), watch(\.microphoneCaptureState)]
        readPage()
    }

    private func readPage() {
        let page = livePage
        func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<BrowserTab, Value>, _ value: Value) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        set(\.liveURL, page?.url)
        set(\.liveTitle, page?.title ?? "")
        set(\.liveIsLoading, page?.isLoading ?? false)
        set(\.liveProgress, page?.estimatedProgress ?? 0)
        set(\.liveCanGoBack, page?.canGoBack ?? false)
        set(\.liveCanGoForward, page?.canGoForward ?? false)
        set(\.cameraCapture, page?.cameraCaptureState ?? .none)
        set(\.microphoneCapture, page?.microphoneCaptureState ?? .none)
    }

    /// Lets the live page go: its observers, its delegate, and what was copied from it.
    private func releasePage() {
        #if os(macOS)
        // A docked inspector holds the page's frame.
        if let livePage { WebInspector.close(on: livePage) }
        #endif
        observations = []
        livePage?.navigationDelegate = nil
        livePage?.uiDelegate = nil
        livePage?.stopLoading()
        livePage?.removeFromSuperview()
        livePage = nil
        pageDelegate = nil
        #if os(macOS)
        WebViewResponder.shared.forget(id)
        #endif
        readPage()
    }

    /// Is there any work behind showing this window — a page to build, an address waiting to load? A
    /// window that is ready costs nothing to show, and the focus can be moved through it for free.
    var needsBuilding: Bool {
        guard !showsStartPage, builtIn == nil, pendingApp == nil else { return false }
        return livePage == nil || pendingURL != nil
    }

    /// The window is coming on screen: it needs a page, and if it was waiting to load, it loads.
    ///
    /// A window still on the start page is the exception — Savoia's start page is SwiftUI, and building a
    /// page for it would spend a web content process on a text field.
    func prepareForDisplay() {
        guard !showsStartPage, builtIn == nil, pendingApp == nil else { return }
        materialize()
        resumeIfNeeded()
    }

    /// Gives the page back to the system. The window keeps its address, title, session
    /// state and thumbnail, and builds the same page again the next time it is shown — which is what
    /// makes this discarding rather than closing. Called by `LivePageCache`, never by the views.
    func discard() {
        guard let page = livePage else { return }
        savedTitle = title
        savedURL = page.url ?? savedURL
        // A page still waiting for its state has none of its own to take.
        if pendingURL == nil {
            savedState = liveState
            savedCanGoBack = page.canGoBack
            savedCanGoForward = page.canGoForward
        }
        // A document is never waiting on an address: its preview is rendered from the text again by
        // `DocumentView` as soon as the column is back on screen.
        if !showsStartPage, isWebPage, let url = page.url { pendingURL = url }
        settleLoads()
        // A question belongs to the page that asked it. This one is going.
        permissions?.forget(id)
        releasePage()
        // Nothing will report on the web view that is going; the next one starts from its own state.
        displayCapture = .none
        generation += 1
        // Nothing asynchronous here on purpose: an `await` on the way out means something is holding
        // the page while it waits, and a page that is held is a page that was not given back. The
        // picture was taken while the window was still on screen (`rememberViewState`), which is
        // also the only time it can be taken at all.
    }

    /// The tab is closing: stop the page for good.
    func close() {
        settleLoads()
        onNavigation = nil
        onDocumentLink = nil
        onLinkBehind = nil
        onPageWindow = nil
        onPageClose = nil
        onDownload = nil
        permissions?.forget(id)
        #if os(macOS)
        dialogs.dismissAll()
        #endif
        releasePage()
        thumbnail = nil
        cache?.forget(id)
        thumbnails?.remove(id)
    }

    // MARK: What survives a move to another profile

    /// A window apart from the store its page was built against: WebKit's session state — the
    /// back-forward list, each entry with its scroll offset — and how it last looked.
    ///
    /// A web view's data store is fixed when the view is built, so a window cannot be handed another
    /// profile's cookies. Moving one between profiles is therefore a rebuild
    /// (`BrowserState.moveTab(_:toProfile:)`), and this is what the window built in its place is given.
    struct Trail {
        var state: Data?
        var picture: PlatformImage?
    }

    var trail: Trail {
        Trail(state: pendingURL == nil ? liveState : savedState, picture: thumbnail)
    }

    /// Takes over from the window this one was built to replace, before it is first shown.
    func adopt(_ trail: Trail) {
        savedState = trail.state
        thumbnail = trail.picture
    }

    /// A state above this is not written to the snapshot, which is rewritten on every change:
    /// `history.state` can be megabytes. Such a window comes back after a relaunch at its address.
    nonisolated static let stateLimit = 512 * 1024

    /// The state of the page as it stands.
    private var liveState: Data? {
        guard isWebPage else { return nil }
        return livePage?.interactionState as? Data
    }

    /// What the page's delegate saw of a navigation.
    func pageDid(_ event: PageDelegate.Event, in page: WKWebView) {
        guard livePage === page else { return }
        switch event {
        case .started:
            // The window is trying again, whatever it was showing before.
            loadFailure = nil
            if mediaHold == .shown { releaseMediaHold() }
        case .committed:
            loadFailure = nil
            if mediaHold == .loading { mediaHold = .shown }
            hasCommitted = true
            savedURL = page.url ?? savedURL
            // Redirects and history moves never ask the delegate for a policy.
            blocker?.note(id, showing: page.url)
            extensions?.noteChanged(self, [.URL, .loading])
            // What was captured belonged to the page being left, and so did what was selected in it
            // and the tools it declared.
            devTools?.noteNavigation(id)
            pageFocus?.noteNavigation(id)
            webMCP?.noteNavigation(id)
            // So did a question nobody answered: the page that asked is gone.
            permissions?.forget(id)
            onNavigation?(self, .committed)
        case .finished:
            savedURL = page.url ?? savedURL
            savedTitle = page.title ?? ""
            extensions?.noteChanged(self, [.title, .loading])
            onNavigation?(self, .finished)
            settleLoads()
            // Only to give a window that has never been drawn something to show; the picture that
            // matters is taken when it leaves the screen.
            if thumbnail == nil { rememberViewState(force: true) }
        case .failedProvisional(let error):
            settleLoads()
            noteFailure(error)
        case .ended:
            settleLoads()
        }
    }

    /// The delegate cancelled a navigation of the main frame, and WebKit reports nothing after that.
    func navigationCancelled() {
        Task { [weak self] in
            guard let self, self.livePage?.isLoading != true else { return }
            self.settleLoads()
        }
    }

    /// What a failed load leaves behind: a sentence, and whether Savoia has an answer to it.
    private func noteFailure(_ error: any Error) {
        let failure = error as NSError
        // Cancelled is not a failure. `stop()` looks like this, and so does the delegate sending a
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
        // about to say, and reading it back is the only way to tell "Savoia has no answer to this"
        // from "Savoia had one and never looked".
        let offer = offered.map { " — Savoia carries \($0.id), switched off" } ?? ""
        devTools?.noteLoadFailure(id,
                                  url: url?.absoluteString ?? "",
                                  reason: "\(failure.localizedDescription) (\(failure.domain) \(failure.code))\(offer)")
    }

    // MARK: What the window knows without a page

    var title: String {
        if let document { return document.title }
        if let app { return app.title }
        if let builtIn { return pageTitle ?? builtIn.title }
        if let pendingApp { return pendingApp.toolTitle }
        if showsStartPage { return String(localized: "New Tab") }
        if !liveTitle.isEmpty { return liveTitle }
        if !savedTitle.isEmpty { return savedTitle }
        return currentURL?.host() ?? "New Tab"
    }

    /// The page's URL, the one a waiting window will load, or the last one it had. A document has
    /// none, and neither has an app: `mcp-app://…` is an address nobody can type, revisit or bookmark.
    var currentURL: URL? {
        // Savoia's own pages have an address, and it is the one thing about them worth showing: it can
        // be typed, and it says what the window is.
        if let builtIn { return builtIn.url(section: section) }
        guard isWebPage else { return nil }
        if let pendingURL { return pendingURL }
        return liveURL ?? savedURL
    }

    var isLoading: Bool { liveIsLoading }
    var estimatedProgress: Double { liveProgress }

    var canGoBack: Bool { liveCanGoBack || (pendingURL != nil && savedCanGoBack) }
    var canGoForward: Bool { liveCanGoForward || (pendingURL != nil && savedCanGoForward) }

    /// A window waiting on its session state is given it first: the list is in there.
    func goBack() {
        resumeIfNeeded()
        guard let item = livePage?.backForwardList.backItem else { return }
        awaitsNavigation = true
        livePage?.go(to: item)
    }

    func goForward() {
        resumeIfNeeded()
        guard let item = livePage?.backForwardList.forwardItem else { return }
        awaitsNavigation = true
        livePage?.go(to: item)
    }

    /// Is there anything here to fetch again? A document is rendered from text Savoia is holding, Savoia's
    /// own pages are drawn rather than loaded, and a start page has never been anywhere.
    var canReload: Bool { isWebPage && currentURL != nil }

    /// The guard is here rather than on the menu item, because a menu item cannot be greyed out on
    /// an answer that changes with every navigation and does not rebuild the menu (`ViewCommands`).
    /// `⌘R` on a document is a key with nothing to do, and does nothing — asking `page` for one
    /// would build a web view for a window that is text Savoia is holding.
    func reload() {
        guard canReload else { return }
        awaitsNavigation = true
        page.reload()
    }

    /// The reload that does not believe the cache — everything is asked of the network again.
    func reloadFromOrigin() {
        guard canReload else { return }
        awaitsNavigation = true
        page.reloadFromOrigin()
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

    /// The one button on the failure page that is not a retry: switch on the authority Savoia was
    /// carrying all along, and ask for the site again.
    ///
    /// It is the same switch as the one in `savoia://settings` ▸ Privacy ▸ Certificates and it is
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
        guard pendingURL != nil else { return }
        if isWebPage, let state = savedState { resume(from: state) } else { resumeByAddress() }
    }

    private func resumeByAddress() {
        guard let url = pendingURL else { return }
        savedState = nil
        let page = beginResume()
        LivePageCache.log("resumed \(title) by its address")
        awaitsNavigation = true
        page.load(URLRequest(url: url))
    }

    private func resume(from state: Data) {
        savedState = nil
        let view = beginResume()
        awaitsNavigation = true
        view.interactionState = state
        LivePageCache.log("resumed \(title) from its session state")
    }

    @discardableResult
    private func beginResume() -> WKWebView {
        savedURL = pendingURL ?? savedURL
        pendingURL = nil
        isResuming = true
        if isWebPage {
            pageControllers?.setUserScripts([MediaHold.script], named: MediaHold.scriptName, for: id)
            mediaHold = .loading
        }
        loadStartedAt = Date()
        return materialize()
    }

    func load(_ url: URL) {
        // An address of Savoia's own is not something WebKit can be asked to fetch: it is a page Savoia
        // draws, so it becomes a window rather than a navigation.
        if let parsed = BuiltInPage.parse(url) {
            onBuiltInAddress?(self, parsed.page, parsed.section)
            return
        }
        // A magnet link pasted into the address bar, or handed over by anything else that calls
        // this: the system's, not WebKit's. `load` would silently do nothing with it.
        if ExternalScheme.isExternal(url) {
            ExternalScheme.open(url)
            return
        }
        guard isWebPage else { return }
        releaseMediaHold()
        showsStartPage = false
        pendingURL = nil
        savedTitle = ""
        savedURL = url
        savedState = nil
        loadStartedAt = Date()
        // Into or out of an extension's own page is another configuration, and so another view.
        if livePage != nil, showsExtensionPage != (extensions?.isExtensionPage(url, profileID: profileID) == true) {
            releasePage()
            generation += 1
        }
        awaitsNavigation = true
        page.load(URLRequest(url: url))
    }

    /// Becomes the window a page opened; WebKit loads into the view this answers with.
    func open(byPageWith configuration: WKWebViewConfiguration) -> WKWebView {
        showsStartPage = false
        isOpenedByPage = true
        openerConfiguration = configuration
        awaitsNavigation = true
        loadStartedAt = Date()
        return page
    }

    /// An extension has loaded: a view showing one of its pages on a plain configuration is built again.
    func extensionLoaded() {
        guard isWebPage, livePage != nil, !showsExtensionPage, let url = loadFailure?.url ?? currentURL,
              extensions?.isExtensionPage(url, profileID: profileID) == true else { return }
        loadFailure = nil
        load(url)
    }

    /// A document's preview, rendered again.
    func load(html: String, baseURL: URL) {
        awaitsNavigation = true
        page.loadHTMLString(html, baseURL: baseURL)
    }

    /// Waits for the navigation under way to end, or for the ceiling.
    func loadSettled(timeout: TimeInterval = 15) async {
        guard awaitsNavigation || isLoading else { return }
        let key = UUID()
        let ceiling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.loadWaiters.removeValue(forKey: key)?.resume()
        }
        await withCheckedContinuation { loadWaiters[key] = $0 }
        ceiling.cancel()
    }

    private func settleLoads() {
        awaitsNavigation = false
        isResuming = false
        let waiting = loadWaiters
        loadWaiters = [:]
        waiting.values.forEach { $0.resume() }
    }

    func navigate(to input: String) {
        // A person who pastes `magnet:?xt=…` into the address bar means the app that claims it. This
        // lives here and not in `fromUserInput`, which the assistant's and the agents' tools also
        // call: what Savoia cannot show they get a search for, not the power to launch whatever app has
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

    private func releaseMediaHold() {
        guard mediaHold != nil else { return }
        mediaHold = nil
        pageControllers?.setUserScripts([], named: MediaHold.scriptName, for: id)
    }

    // MARK: Eviction guards and the thumbnail

    /// Is the page playing something? A page with sound or video is not an eviction candidate.
    var isPlayingMedia: Bool {
        get async {
            guard let livePage else { return false }
            return await livePage.requestMediaPlaybackState() == .playing
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
            // An app is unsaved work by definition — its whole state lives in a document Savoia
            // cannot rebuild — so it is never the window the budget takes back.
            if isApp { return true }
            guard livePage != nil, !isDocument else { return false }
            let script = """
            var drafts = Array.from(document.querySelectorAll('textarea')).some(function (element) {
                return element.value.trim().length > 20;
            });
            var secrets = Array.from(document.querySelectorAll('input[type=password]')).some(function (element) {
                return element.value !== '';
            });
            return drafts || secrets
            """
            return (try? await callWithoutGesture(script)) as? Bool ?? false
        }
    }

    /// Takes a picture of the page, which the window will need if the page is discarded, while it is
    /// still on screen: an unmounted web view has nothing to draw.
    ///
    /// Best effort and rate limited: it costs a round trip to the web content process, and a slightly
    /// stale picture is worth more than none.
    ///
    /// The task is handed back for a caller that has to wait for the picture.
    @discardableResult
    func rememberViewState(force: Bool = false) -> Task<Void, Never>? {
        // A page still waiting to load has nothing to draw, and asking it would start the load.
        guard let page = livePage, !showsStartPage, pendingURL == nil, !page.isLoading else { return nil }
        guard force || Date().timeIntervalSince(lastThumbnailAt) > 3 else { return nil }
        lastThumbnailAt = Date()
        let region = CGRect(origin: .zero, size: displaySize)
        return Task {
            // Asked alongside the picture and not before it: a tab on its way off screen is mounted
            // for this turn only, and a round trip in front of the snapshot may not survive.
            async let viewport = self.callWithoutGesture("return [window.innerWidth, window.innerHeight]")
            // `afterScreenUpdates: false` takes what is already rendered: a tab on its way off screen
            // will never get another screen update. 400 pt wide: a ring card is never drawn bigger.
            let configuration = WKSnapshotConfiguration()
            configuration.rect = region
            configuration.snapshotWidth = 400
            configuration.afterScreenUpdates = false
            let clock = ContinuousClock()
            let started = clock.now
            let taken = try? await page.takeSnapshot(configuration: configuration)
            let measured = (try? await viewport) as? [Double]
            guard let image = taken, image.size.width > 1, let data = image.pngData else {
                LivePageCache.log("no picture of \(self.title)")
                return
            }
            // A page that is not the width of its column has no view to be that width in: it was
            // taken off the screen before the picture was, and WebKit lays such a page out at 1024×768.
            // Its picture is that page in the corner of the rectangle and nothing in the rest, and the
            // one already in hand is better. Only taller is wrong: a find or translation bar over the
            // page leaves it shorter than its column, and that picture is fine. The Mac only: on a
            // phone a page with no viewport tag is laid out 980 wide whatever the screen is.
            #if os(macOS)
            if let measured, measured.count == 2,
               abs(measured[0] - region.width) > 4 || measured[1] > region.height + 4 {
                LivePageCache.log("kept the old picture of \(self.title): the page is \(Int(measured[0]))×\(Int(measured[1])), its column \(Int(region.width))×\(Int(region.height))")
                return
            }
            #endif
            LivePageCache.log("drew \(self.title) at \(Int(image.size.width))×\(Int(image.size.height)), \(data.count / 1024) KB, in \(started.duration(to: clock.now))")
            self.pictureIsStale = false // this one is of the shape the window is now
            self.thumbnail = image
            self.cache?.notePicture(self)
            self.thumbnails?.write(data, for: self.id)
        }
    }
}

extension URL {
    /// Turns address-bar input into a URL: scheme-less hosts get `https://`, everything else becomes a search.
    static func fromUserInput(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme,
           ["http", "https", "file", "about", "savoia"].contains(scheme) {
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
