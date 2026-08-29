#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI
import WebKit

/// App-wide browser model: profiles (each with an isolated data store) and tabs across all profiles,
/// arranged by `NiriLayout` into per-profile strips of workspaces.
@MainActor
@Observable
final class BrowserState {
    private(set) var profiles: [Profile]
    private(set) var tabs: [BrowserTab] = []
    var selectedProfileID: Profile.ID
    var selectedTabID: BrowserTab.ID?

    /// niri-style layout: the focused column here is the selected tab.
    let layout = NiriLayout()
    /// The app-wide budget for live `WebPage`s — one queue across every profile and every workspace,
    /// which is what makes stepping out of a workspace and back cheap. See `LivePageCache`.
    let pages = LivePageCache()
    /// The pictures of the windows, kept as files so the overview is not blank after a relaunch.
    @ObservationIgnored let thumbnails = PageThumbnails()
    /// Visits, per profile.
    let history: HistoryStore
    /// Saved pages, per profile; wired at launch. Removing a profile removes its bookmarks.
    @ObservationIgnored var bookmarks: BookmarkStore?
    /// The Markdown files behind document windows.
    @ObservationIgnored let documents = DocumentStore()
    /// Highlights per URL; wired at launch.
    @ObservationIgnored var highlights: HighlightStore?
    /// Ad and tracker blocking. Assigning it reaches the windows that already exist — a window
    /// restored from the snapshot is built before anything is wired, and an unprotected window is
    /// exactly what the blocker is for.
    @ObservationIgnored var blocker: ContentBlocker? {
        didSet { for tab in tabs { tab.blocker = blocker } }
    }
    /// Browser extensions, one controller per profile; see `ExtensionStore`.
    @ObservationIgnored var extensions: ExtensionStore? {
        didSet { for tab in tabs { tab.extensions = extensions } }
    }
    /// The `WKUserContentController` of every open window — the blocker's rules and the devtools
    /// hooks go into it (`PageControllers`).
    @ObservationIgnored let pageControllers: PageControllers
    /// Console and network capture, and Web Inspector; wired at launch.
    @ObservationIgnored var devTools: DevToolsStore? {
        didSet { for tab in tabs { tab.devTools = devTools } }
    }
    /// The camera, the microphone and the motion sensors, per site (`SitePermissions`). Handed to
    /// the initializer for the same reason as the blocker: the windows it restores are built and
    /// answered before anything assigned afterwards could reach them.
    @ObservationIgnored var permissions: SitePermissions? {
        didSet { for tab in tabs { tab.permissions = permissions } }
    }
    /// Files the pages asked to save (`DownloadStore`). One list for the app, like the strip's
    /// pictures: a download belongs to the browser, not to the window that started it — closing the
    /// window must not stop the transfer.
    let downloads = DownloadStore()
    /// The mark that flies from a click to the downloads button (`FlightStore`).
    let flights = FlightStore()
    /// Deep-research runs (see `ResearchRun`).
    var research: [ResearchRun] = []
    @ObservationIgnored private let settings: SettingsStore

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// Tabs by id. The strip asks for one per column per layout pass, and a linear scan over a
    /// hundred windows on every pass is a hundred times nothing that adds up to something.
    @ObservationIgnored private var tabsByID: [UUID: BrowserTab] = [:]

    /// Starts from a snapshot when there is one; otherwise with the default profiles and one window.
    /// `pageControllers`, `blocker` and `devTools` are arguments rather than properties assigned
    /// afterwards because this initializer *builds and loads* the first windows: anything wired later
    /// would arrive after that page had already started loading.
    init(snapshot: BrowserSnapshot? = nil, history: HistoryStore, settings: SettingsStore,
         pageControllers: PageControllers? = nil, blocker: ContentBlocker? = nil,
         devTools: DevToolsStore? = nil, permissions: SitePermissions? = nil) {
        self.history = history
        self.settings = settings
        self.pageControllers = pageControllers ?? PageControllers()
        self.blocker = blocker
        self.devTools = devTools
        self.permissions = permissions
        layout.centersFocus = settings.centersFocus
        layout.preferredWidthIndex = settings.columnWidthIndex
        var loaded = snapshot?.profiles ?? Self.legacyProfiles() ?? Profile.defaults
        if loaded.isEmpty { loaded = Profile.defaults }
        profiles = loaded
        let selected = loaded.first { $0.id == snapshot?.selectedProfileID }?.id ?? loaded[0].id
        selectedProfileID = selected
        layout.activeProfileID = selected
        if let snapshot { restore(snapshot) }
        research = (snapshot?.research ?? []).filter { run in tabs.contains { $0.id == run.documentTabID } }
        for i in research.indices { research[i].isRunning = false } // nothing survives a relaunch mid-turn
        layout.setPreferredWidth(settings.columnWidthIndex) // one width everywhere, whatever the file says
        if layout.hasColumns { syncSelection() } else { newTab() }
        pages.setBudget(settings.livePageBudget)
        thumbnails.prune(keeping: Set(tabs.map(\.id))) // windows closed in a launch that never cleaned up
        trackVisibleWindows()
        refreshLivePages() // the first strip, before any change has had a chance to fire
    }

    // MARK: Live pages

    /// Keeps the live-page budget pointed at what the strip is showing. Every layout change — focus,
    /// workspace, scroll, resize, overview, a new window — moves `visibleTabIDs`, and this follows it
    /// without the views having to say anything: building and discarding pages is the model's job,
    /// and doing it from a view body would be mutating state in the middle of drawing it.
    private func trackVisibleWindows() {
        withObservationTracking {
            _ = layout.visibleTabIDs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshLivePages()
                trackVisibleWindows()
            }
        }
    }

    /// How many windows may hold a live page at once, from the menu.
    func setLivePageBudget(_ value: Int) {
        settings.livePageBudget = value
        pages.setBudget(value)
    }

    /// True while the overview is up, so entering it can be told from moving around inside it.
    @ObservationIgnored private var showingOverview = false
    @ObservationIgnored private var shownTabIDs: Set<UUID> = []

    private func refreshLivePages() {
        let visible = layout.visibleTabIDs
        // On the way into the overview every window on screen is about to become a card: this is the
        // last moment any of them can be drawn.
        if layout.isOverview, !showingOverview {
            for id in shownTabIDs { tabsByID[id]?.rememberViewState(force: true) }
            // The rest of the strip is about to be drawn as cards: the ones with no picture in memory
            // — never shown this launch, or dropped for the budget — read theirs off disk. Only this
            // profile's: the overview shows one strip, and the others are not on screen to be drawn.
            for tab in tabs(in: selectedProfileID) { tab.loadPictureIfNeeded() }
        }
        showingOverview = layout.isOverview
        shownTabIDs = visible
        // Each window's own width, so the picture taken of it is the shape of the column it fills.
        if let workspace = layout.focusedWorkspace {
            let frames = layout.columnFrames(workspace)
            for (index, column) in workspace.columns.enumerated() where frames.indices.contains(index) {
                guard visible.contains(column.tabID) else { continue }
                tabsByID[column.tabID]?.displaySize = frames[index].size
            }
        }
        // Only the focused window is loaded. Everything else on screen is pinned — a neighbour that
        // still has its page goes on showing it — but nothing is built for walking past it, and the
        // overview builds nothing at all.
        let building = layout.isOverview ? nil : layout.focusedTabID
        pages.setVisible(visible, building: building) { [weak self] id in self?.tabsByID[id] }
    }

    // MARK: Snapshot

    /// A private profile leaves nothing here: not the profile, not its windows, not its strip.
    var snapshot: BrowserSnapshot {
        let privateIDs = Set(profiles.filter(\.isPrivate).map(\.id))
        let selected = privateIDs.contains(selectedProfileID) ? (profiles.first { !$0.isPrivate }?.id ?? selectedProfileID) : selectedProfileID
        return BrowserSnapshot(
            profiles: profiles.filter { !$0.isPrivate },
            selectedProfileID: selected,
            tabs: tabs.filter { !privateIDs.contains($0.profileID) }.map { tab in
                var entry = TabSnapshot(id: tab.id, profileID: tab.profileID, url: tab.showsStartPage ? nil : tab.currentURL, title: tab.title)
                if let document = tab.document {
                    entry.document = DocumentSnapshot(id: document.id, title: document.title, modifiedAt: document.modifiedAt,
                                                      fileURL: document.fileURL, showsPreview: document.showsPreview)
                }
                return entry
            },
            strips: layout.allStrips
                .filter { !privateIDs.contains($0.key) }
                .map { StripSnapshot(profileID: $0.key, strip: $0.value) }
                .sorted { $0.profileID.uuidString < $1.profileID.uuidString },
            research: research.filter { !privateIDs.contains($0.profileID) }
        )
    }

    /// Document text is autosaved on its own; this is for the way out. A private profile's documents
    /// were never on disk and stay that way.
    func flushDocuments() {
        documents.flush(tabs.filter { !isPrivate($0.profileID) }.compactMap(\.document))
    }

    func isPrivate(_ profileID: Profile.ID) -> Bool {
        profiles.first { $0.id == profileID }?.isPrivate ?? false
    }

    /// Rebuilds tabs and strips, dropping what doesn't line up: a column without a tab, a tab no column
    /// points at, anything belonging to a profile that is gone. Pages load lazily (see `BrowserTab`).
    private func restore(_ snapshot: BrowserSnapshot) {
        let profileIDs = Set(profiles.map(\.id))
        let saved = Dictionary(snapshot.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var strips: [UUID: NiriStrip] = [:]
        var placed = Set<UUID>()
        for entry in snapshot.strips where profileIDs.contains(entry.profileID) {
            var strip = entry.strip
            for i in strip.workspaces.indices {
                strip.workspaces[i].columns.removeAll { column in
                    guard let tab = saved[column.tabID], tab.profileID == entry.profileID, !placed.contains(tab.id) else { return true }
                    placed.insert(tab.id)
                    return false
                }
            }
            strips[entry.profileID] = strip
        }
        for tab in snapshot.tabs where placed.contains(tab.id) {
            guard let profile = profiles.first(where: { $0.id == tab.profileID }) else { continue }
            if let saved = tab.document {
                let text = documents.load(id: saved.id) ?? "# \(saved.title)\n"
                let document = TextDocument(id: saved.id, text: text, modifiedAt: saved.modifiedAt, fileURL: saved.fileURL, showsPreview: saved.showsPreview)
                add(makeDocumentTab(id: tab.id, profile: profile, document: document))
            } else {
                add(makeTab(id: tab.id, profile: profile, restoring: tab.url, title: tab.title))
            }
        }
        layout.restore(strips: strips)
    }

    /// Profiles used to live in `UserDefaults`; read them once for the first launch with a snapshot file.
    private static func legacyProfiles() -> [Profile]? {
        guard let data = UserDefaults.standard.data(forKey: "six.profiles"),
              let stored = try? JSONDecoder().decode([Profile].self, from: data), !stored.isEmpty else { return nil }
        return stored
    }

    // MARK: Profiles

    var selectedProfile: Profile {
        profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    /// Persistent per profile; in memory for a private one — the same store for every window of the
    /// profile, so a login made in one private window holds in the next, and gone with the profile.
    func dataStore(for profile: Profile) -> WKWebsiteDataStore {
        if let store = dataStores[profile.dataStoreID] { return store }
        let store = profile.isPrivate ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
        dataStores[profile.dataStoreID] = store
        return store
    }

    func selectProfile(_ id: Profile.ID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        layout.activeProfileID = id
        if layout.hasColumns {
            syncSelection()
        } else {
            newTab(in: id)
        }
    }

    func addProfile(name: String, colorHex: String) {
        let profile = Profile(name: name, colorHex: colorHex)
        profiles.append(profile)
        selectProfile(profile.id)
    }

    func removeProfile(_ id: Profile.ID) {
        guard profiles.count > 1, let profile = profiles.first(where: { $0.id == id }) else { return }
        for tab in tabs(in: id) { closeTab(tab.id) }
        research.removeAll { $0.profileID == id }
        profiles.removeAll { $0.id == id }
        dataStores[profile.dataStoreID] = nil // a private store dies with its last reference: that is the whole point
        layout.removeProfile(id)
        permissions?.forgetProfile(id) // what a site was allowed inside this profile went with it
        if !profile.isPrivate {
            bookmarks?.removeAll(in: id)
            history.clear(profileID: id)
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID) }
        }
        if selectedProfileID == id { selectProfile(profiles.first { !$0.isPrivate }?.id ?? profiles[0].id) }
    }

    // MARK: Private browsing

    /// The private profile, if one is open. There is one at a time — its windows share a session, the
    /// way Safari's private windows do.
    var privateProfile: Profile? { profiles.first(where: \.isPrivate) }

    /// A window in the private profile, creating the profile on the first call. ⌘⇧P.
    @discardableResult
    func newPrivateWindow(url: URL? = nil) -> BrowserTab {
        if let existing = privateProfile { return newTab(url: url, in: existing.id) }
        let profile = Profile(name: Profile.privateName, colorHex: Profile.privateColorHex, isPrivate: true)
        profiles.append(profile)
        selectedProfileID = profile.id
        layout.activeProfileID = profile.id
        return newTab(url: url, in: profile.id)
    }

    /// Closes every private window, forgets the profile, and with it the in-memory site data.
    func closePrivateBrowsing() {
        guard let profile = privateProfile else { return }
        removeProfile(profile.id)
    }

    /// Wipes the profile's site data — cookies, local storage, IndexedDB, caches, everything the
    /// `WKWebsiteDataStore` holds — then reloads the profile's open pages, so the screen shows the
    /// signed-out state rather than a stale render. Restored windows that haven't loaded yet need
    /// nothing: they load fresh when shown.
    func clearSiteData(for id: Profile.ID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        await dataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for tab in tabs(in: id) where !tab.showsStartPage && tab.pendingURL == nil {
            _ = tab.livePage?.reload(fromOrigin: true)
        }
    }

    /// The profile's agent folder, created on first use. Nil (default) puts it back under Application Support.
    func setWorkingDirectory(_ url: URL?, for id: Profile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].workingDirectoryPath = url?.standardizedFileURL.path
    }

    /// Ensures the profile's working directory exists and returns it.
    func workingDirectory(for profile: Profile) -> URL {
        let url = profile.workingDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Tabs

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func tab(_ id: BrowserTab.ID) -> BrowserTab? {
        tabsByID[id]
    }

    /// Every tab goes through here, so nothing is in `tabs` without an index entry and a page budget.
    private func add(_ tab: BrowserTab) {
        tab.cache = pages
        tab.thumbnails = thumbnails
        tab.blocker = blocker
        tab.extensions = extensions
        tab.pageControllers = pageControllers
        tab.devTools = devTools
        tab.permissions = permissions
        extensions?.noteOpened(tab)
        tabs.append(tab)
        tabsByID[tab.id] = tab
    }

    func tabs(in profileID: Profile.ID) -> [BrowserTab] {
        tabs.filter { $0.profileID == profileID }
    }

    @discardableResult
    func newTab(url: URL? = nil, in profileID: Profile.ID? = nil) -> BrowserTab {
        newTab(url: url, in: profileID, workspace: nil, activate: true)
    }

    /// Opens a window in a specific workspace of a profile's strip. With `activate` off (an agent adding
    /// windows in the background) nothing on screen changes — not even the profile.
    @discardableResult
    func newTab(url: URL?, in profileID: Profile.ID?, workspace: Int?, activate: Bool) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = makeTab(profile: profile)
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate)
        }
        if activate { syncSelection() }
        if let url { tab.load(url) }
        return tab
    }

    private func makeTab(id: UUID = UUID(), profile: Profile, restoring url: URL? = nil, title: String = "") -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, dataStore: dataStore(for: profile), restoring: url, title: title)
        tab.onNavigation = { [weak self] tab, outcome in
            guard let self, let page = tab.livePage, let url = page.url else { return }
            switch outcome {
            case .committed: if !profile.isPrivate { history.record(url, title: page.title, in: tab.profileID) }
            case .finished:
                guard !profile.isPrivate else { return } // no history, and highlights are not stored for it
                history.updateTitle(page.title, for: url, in: tab.profileID)
                highlights?.apply(to: tab)
            }
        }
        tab.onNewWindow = { [weak self] tab, request, behind in
            guard let url = request.url else { return }
            self?.openInNewWindow(url, from: tab, background: behind)
        }
        tab.onDownload = { [weak self] tab, request, suggestedName in
            self?.download(request, suggestedName: suggestedName, from: tab)
        }
        return tab
    }

    // MARK: A second window, and a file

    /// Open Link, from the page's context menu. A page window goes there; a document window never
    /// navigates away from the document, so the link becomes a window of its own (`open(_:from:)`).
    func openLink(_ url: URL, in tab: BrowserTab) {
        if tab.isDocument {
            open(url, from: tab)
        } else {
            tab.load(url)
        }
    }

    /// What ⌘-click, Open Link in New Window and `target=_blank` come to: a column right of the one
    /// the link was in.
    ///
    /// `background` puts it there *behind* — the strip grows to the right and the focus stays on the
    /// page being read, which is what a background tab is everywhere else. A page that opened the
    /// window itself (`window.open`, a `_blank` link clicked plainly) comes forward, because the page
    /// opened it to be looked at.
    func openInNewWindow(_ url: URL, from tab: BrowserTab, background: Bool = false) {
        guard let scheme = url.scheme?.lowercased() else { return }
        guard ["http", "https", "file", "about", "six"].contains(scheme) else {
            #if os(macOS)
            NSWorkspace.shared.open(url) // mailto:, tel:, a custom scheme — the system's business
            #endif
            return
        }
        let opened = newTab(url: url, in: tab.profileID, workspace: nil, activate: !background)
        // Remembered so the column can be taken back if the link turns out to be a file — see
        // `closeIfOnlyCarriedALink`.
        opened.openedForLink = true
        // Only for the ones that go behind: a window that comes forward takes the eye with it and
        // needs no announcing. The one that does not is otherwise invisible — see `NiriLayout.peek`.
        if background { layout.peek() }
    }


    /// Download Linked File, `<a download>`, or a response no page can show.
    func download(_ request: URLRequest, suggestedName: String?, from tab: BrowserTab) {
        let profile = profiles.first { $0.id == tab.profileID } ?? selectedProfile
        downloads.start(request, suggestedName: suggestedName, referrer: tab.currentURL,
                        cookies: dataStore(for: profile))
        flights.launch(from: Self.clickInWindow)
        closeIfOnlyCarriedALink(tab)
    }

    /// A column opened for a link the server then answered with a file has nothing in it: no page
    /// committed, nothing to go back to, and nothing to show but the blank it was born as. It goes
    /// with the download it turned into — the file is in the bar, which is where the answer is.
    ///
    /// A download asked for from a page the user is reading leaves that page alone, and so does one
    /// asked for in a window that had already shown something.
    private func closeIfOnlyCarriedALink(_ tab: BrowserTab) {
        guard tab.openedForLink, !tab.hasCommitted else { return }
        // Not here: this runs inside the policy decision that turned the link into a download, and
        // the page is still waiting for the answer to it. One turn later there is nothing to unwind.
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let tab, !tab.hasCommitted else { return }
            closeTab(tab.id)
        }
    }

    /// Where the pointer is, in the window's own coordinates — the link that was clicked, or the menu
    /// item over it, which is close enough to be the same place. Read now, because by the time the
    /// first byte arrives the mouse has moved on. Nil when the pointer is not in six's window at all:
    /// a download an agent asked for has nowhere to fly from.
    private static var clickInWindow: CGPoint? {
        #if os(macOS)
        // Not `keyWindow`: a download can be asked for from a menu or a popover, and while the app is
        // not the active one there is no key window at all.
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let content = window.contentView
        else { return nil }
        // `convert(_:from: nil)` takes it from the window's coordinates into the content view's, which
        // is flipped — and so is the SwiftUI space the flight is drawn in.
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = content.convert(inWindow, from: nil)
        guard content.bounds.contains(point) else { return nil }
        return point
        #else
        return nil
        #endif
    }

    // MARK: Documents

    /// Opens a document window — a column of text next to the pages. Same placement rules as `newTab`.
    @discardableResult
    func newDocument(text: String = "", in profileID: Profile.ID? = nil, workspace: Int? = nil, activate: Bool = true) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let document = TextDocument(text: text)
        let tab = makeDocumentTab(profile: profile, document: document)
        if !profile.isPrivate { documents.save(document) }
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate)
        }
        if activate { syncSelection() }
        return tab
    }

    private func makeDocumentTab(id: UUID = UUID(), profile: Profile, document: TextDocument) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, document: document)
        if !profile.isPrivate { documents.watch(document) } // private: in memory only, like everything else there
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        return tab
    }

    /// A link from a document: the window that already shows the page (fragment and all) if there is
    /// one in the profile, otherwise a new window next to the document. A `#:~:text=` fragment is
    /// what makes the page scroll to the cited passage.
    func open(_ url: URL, from tab: BrowserTab) {
        let target = url.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url.absoluteString
        if let existing = tabs(in: tab.profileID).first(where: { candidate in
            guard !candidate.isDocument, let current = candidate.currentURL else { return false }
            return current.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) == target
        }) {
            selectTab(existing.id)
            existing.resumeIfNeeded()
            if url.fragment() != nil { existing.load(url) }
            highlights?.scroll(existing, toHighlightMatching: url)
            return
        }
        newTab(url: url, in: tab.profileID)
    }

    // MARK: Research

    func run(forWorkspace workspaceID: UUID) -> ResearchRun? {
        research.first { $0.workspaceID == workspaceID }
    }

    func run(forDocument tabID: UUID) -> ResearchRun? {
        research.first { $0.documentTabID == tabID }
    }

    /// The run the focused workspace belongs to, if any.
    var focusedRun: ResearchRun? {
        guard let workspace = layout.focusedWorkspace else { return nil }
        return run(forWorkspace: workspace.id)
    }

    func update(_ run: ResearchRun) {
        if let index = research.firstIndex(where: { $0.id == run.id }) { research[index] = run } else { research.append(run) }
    }

    /// A window opened into a workspace with a live run is one of its sources.
    func noteSource(_ tab: BrowserTab, workspace index: Int) {
        let strip = layout.strip(for: tab.profileID)
        guard strip.workspaces.indices.contains(index), var run = run(forWorkspace: strip.workspaces[index].id),
              !run.sourceWindowIDs.contains(tab.id) else { return }
        run.sourceWindowIDs.append(tab.id)
        update(run)
    }

    /// Moves a window to a workspace of its own profile's strip; the focus stays where it is.
    func moveTab(_ id: BrowserTab.ID, toWorkspace index: Int) {
        guard let tab = tab(id) else { return }
        withAnimation(NiriLayout.switchAnimation) {
            layout.moveColumn(tabID: id, in: tab.profileID, toWorkspace: index)
        }
        syncSelection()
    }

    func selectTab(_ id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        extensions?.noteActivated(tab)
        if selectedProfileID != tab.profileID {
            selectedProfileID = tab.profileID
            layout.activeProfileID = tab.profileID
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.focus(tabID: id)
        }
        pages.touch(id)
        syncSelection()
    }

    /// Every window gives its page back and builds it again. A page's configuration is fixed when the
    /// page is built — its content controller, its extension controller — so anything that changes
    /// what a page should be built *with* has to go through here. Windows keep their address, their
    /// history and their picture, as they do for any other discard.
    func rebuildLivePages() {
        for tab in tabs where tab.hasLivePage { tab.discard() }
        selectedTab?.prepareForDisplay()
    }

    /// The shield in this window's address field: allow ads on the site it is showing, or block
    /// them again. The rules move with the next load, so the window reloads to show the difference.
    func setBlockingAllowed(_ allowed: Bool, for tab: BrowserTab) {
        guard let blocker, let url = tab.currentURL else { return }
        blocker.setAllowed(allowed, for: url)
        blocker.note(tab.id, showing: url)
        _ = tab.page.reload()
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        tabsByID[id] = nil
        closed.close() // drops its page, its place in the budget and its picture
        blocker?.forget(id)
        extensions?.noteClosed(closed)
        devTools?.forget(id)
        pageControllers.forget(id)
        if let document = closed.document {
            documents.remove(id: document.id)
            research.removeAll { $0.documentTabID == closed.id }
        }
        let wasActive = closed.profileID == selectedProfileID
        withAnimation(NiriLayout.switchAnimation) {
            layout.removeColumn(tabID: id)
        }
        // Nothing left to fill the screen with: a filled mode would be a blank wall with no way back.
        if layout.fill != .tiled, layout.focusedWorkspace?.isEmpty != false { layout.setFill(.tiled) }
        guard wasActive else { return }
        syncSelection()
        if selectedTabID == nil, tabs(in: closed.profileID).isEmpty {
            newTab(in: closed.profileID)
        }
    }

    func closeSelectedTab() {
        if let id = selectedTabID { closeTab(id) }
    }

    // MARK: niri operations

    func focusColumn(_ delta: Int) { animateLayout { layout.focusColumn(delta) } }
    func focusColumnEdge(last: Bool) { animateLayout { layout.focusColumnEdge(last: last) } }
    func moveColumn(_ delta: Int) { animateLayout { layout.moveColumn(delta) } }
    func stepColumnWidth(_ delta: Int) {
        animateLayout { layout.stepColumnWidth(delta) }
        settings.columnWidthIndex = layout.preferredWidthIndex
    }

    func setColumnWidth(_ index: Int) {
        animateLayout { layout.setPreferredWidth(index) }
        settings.columnWidthIndex = layout.preferredWidthIndex
    }
    func toggleCompactWidth() { animateLayout { layout.toggleCompactWidth() } }
    func focusWorkspace(_ delta: Int) { animateLayout { layout.focusWorkspace(delta) } }
    func focusWorkspace(at index: Int) { animateLayout { layout.focusWorkspace(at: index) } }
    func moveColumnToWorkspace(_ delta: Int) { animateLayout { layout.moveColumnToWorkspace(delta) } }

    /// Free strip panning is driven directly by the trackpad, so it is deliberately un-animated.
    func panStrip(by delta: CGFloat) {
        layout.panStrip(by: delta)
    }

    func endStripPan() {
        guard !layout.isOverview else { return } // the overview scrolls freely, nothing to snap to
        animateLayout { layout.snapFocusToView() }
    }

    func toggleCenterFocus() {
        animateLayout { layout.setCentersFocus(!layout.centersFocus) }
        settings.centersFocus = layout.centersFocus
    }

    func toggleOverview() {
        NiriLayout.trace("toggleOverview (was \(layout.isOverview ? "open" : "closed"))")
        if layout.isOverview {
            exitOverview()
        } else {
            withAnimation(NiriLayout.switchAnimation) {
                layout.isOverview = true
                layout.recenterStrips() // the overview has its own widths, and fullscreen's are not them
            }
        }
    }

    func exitOverview() {
        NiriLayout.trace("exitOverview (isOverview \(layout.isOverview))")
        guard layout.isOverview else { return }
        withAnimation(NiriLayout.switchAnimation) {
            layout.isOverview = false
            // Free overview scrolling leaves the offset anywhere, and a strip going back to fullscreen
            // changes every width on the way out.
            layout.recenterStrips()
        }
    }

    /// The page fills the window under the top bar; the layout's own controls stay where they are.
    func toggleFullWindow() {
        setFill(layout.fill == .window ? .tiled : .window)
    }

    /// niri's fullscreen: the focused window fills the screen and the strip keeps working under it.
    func toggleFullscreen() {
        setFill(layout.fill == .screen ? .tiled : .screen)
    }

    /// ⎋ leaves fullscreen only: filling the window is ordinary browsing, and a page's own ⎋ is worth
    /// more there than a second way out.
    func exitFullscreen() {
        if layout.fill == .screen { setFill(.tiled) }
    }

    /// Back to the tiled strip, whichever mode was on — the chrome has to come back for the address bar.
    func restoreChrome() {
        setFill(.tiled)
    }

    private func setFill(_ value: NiriFill) {
        guard value != layout.fill else { return }
        // An empty workspace has no page to show edge to edge, and hiding the chrome over nothing only
        // takes away the way back.
        guard value == .tiled || layout.focusedWorkspace?.isEmpty == false else { return }
        // Deliberately not animated. Every switch resizes every live page, and a web view changing
        // size costs a hitch you can see (~50 ms with three of them live); running that through a
        // 0.34 s spring spreads the stutter across the whole animation instead of getting it over
        // with. Measured over six switches: 20 dropped frames animated against 5 instant.
        layout.verticalPreview = 0
        layout.horizontalPreview = 0
        if value != .tiled { layout.isOverview = false }
        layout.setFill(value)
        syncSelection()
    }

    private func animateLayout(_ body: () -> Void) {
        withAnimation(NiriLayout.switchAnimation) {
            layout.verticalPreview = 0
            layout.horizontalPreview = 0
            body()
        }
        syncSelection()
    }

    /// The focused column is the selected tab — everything else (assistant, agent panel, ⌘L) keys off it.
    private func syncSelection() {
        selectedTabID = layout.focusedTabID
    }
}
