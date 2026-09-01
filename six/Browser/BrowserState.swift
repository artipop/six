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
    /// Translating a page in place, and the engine that does it. Both are `@Observable` themselves,
    /// so the reference can be ignored here while the views still see them change.
    @ObservationIgnored let translation = PageTranslator()
    /// Apple's on-device translator. Held by name as well as behind the protocol, because the
    /// hidden `.translationTask` host needs the concrete one — that is the whole point of it.
    @ObservationIgnored let appleTranslator = AppleTranslator()
    /// Deep-research runs (see `ResearchRun`).
    var research: [ResearchRun] = []
    /// Windows that were closed, oldest first — what ⌘⇧T puts back. Observed rather than ignored so
    /// the menu item can go grey the moment the last one is used up.
    private var closedWindows: [ClosedWindow] = []
    /// Whether the strip's edge buttons wait to be found or stand on the screen (`SettingsStore`).
    /// Chrome rather than geometry, so it lives here and not in `NiriLayout`: it changes nothing a
    /// second front end would have to agree with, only whether this one asks for a peek.
    var peeksAtEdges = SettingsStore.peeksByDefault
    @ObservationIgnored private let settings: SettingsStore
    /// Who the profiles are, in the database beside the history and the bookmarks that are keyed by
    /// them. Not the snapshot: see `ProfileStore` for what the snapshot losing them used to cost.
    @ObservationIgnored private let profileStore: ProfileStore

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    /// Tabs by id. The strip asks for one per column per layout pass, and a linear scan over a
    /// hundred windows on every pass is a hundred times nothing that adds up to something.
    @ObservationIgnored private var tabsByID: [UUID: BrowserTab] = [:]

    /// Starts from the profiles in the database and the windows in the snapshot; with the default
    /// profiles and one window when there is neither.
    /// `pageControllers`, `blocker` and `devTools` are arguments rather than properties assigned
    /// afterwards because this initializer *builds and loads* the first windows: anything wired later
    /// would arrive after that page had already started loading.
    init(snapshot: BrowserSnapshot? = nil, history: HistoryStore, settings: SettingsStore,
         profileStore: ProfileStore, pageControllers: PageControllers? = nil, blocker: ContentBlocker? = nil,
         devTools: DevToolsStore? = nil, permissions: SitePermissions? = nil) {
        self.history = history
        self.settings = settings
        self.profileStore = profileStore
        self.pageControllers = pageControllers ?? PageControllers()
        self.blocker = blocker
        self.devTools = devTools
        self.permissions = permissions
        layout.centersFocus = settings.centersFocus
        peeksAtEdges = settings.peeksAtEdges
        // Who the profiles are comes from the table; what was open comes from the snapshot. The two
        // used to be one file, and the day it would not decode the profiles were born again with new
        // data stores behind them — every login in every profile, gone (`ProfileStore`).
        //
        // The table is the only place asked. It could have been seeded from the snapshot on the
        // launch that creates it, and that would have carried the identifiers over once — but it
        // would also have left the reading of `snapshot.profiles` in the code for one launch's sake,
        // where the next person to look would have to work out whether it still ran. An empty table
        // means a new browser, which is the honest reading of an empty table.
        var loaded = profileStore.all().map(Profile.init)
        if loaded.isEmpty {
            loaded = Profile.defaults
            profileStore.save(Self.records(of: loaded))
        }
        profiles = loaded
        let selected = loaded.first { $0.id == snapshot?.selectedProfileID }?.id ?? loaded[0].id
        selectedProfileID = selected
        layout.activeProfileID = selected
        if let snapshot { restore(snapshot) }
        research = (snapshot?.research ?? []).filter { run in tabs.contains { $0.id == run.documentTabID } }
        for i in research.indices { research[i].isRunning = false } // nothing survives a relaunch mid-turn
        if layout.hasColumns { syncSelection() } else { newTab() }
        pages.setBudget(settings.livePageBudget)
        thumbnails.prune(keeping: Set(tabs.map(\.id))) // windows closed in a launch that never cleaned up
        trackVisibleWindows()
        refreshLivePages() // the first strip, before any change has had a chance to fire
        translation.engine = appleTranslator
    }

    // MARK: Translation

    /// After a page settles: is it in a language the reader does not read? Then the address field
    /// gets something to click. A site in `alwaysTranslateHosts` skips the offer and just goes.
    private func offerTranslation(of tab: BrowserTab) {
        let target = settings.translationTarget
        Task {
            guard let plan = try? await translation.plan(tab), plan.refusal == nil,
                  let source = TranslationLanguage.source(of: plan),
                  TranslationLanguage.isForeign(source, to: target) else { return }
            if let host = tab.currentURL?.host(), settings.alwaysTranslateHosts.contains(host) {
                await translation.translate(tab, id: tab.id, from: source, to: target)
            } else {
                translation.offer(source: source, target: target, id: tab.id)
            }
        }
    }

    /// What pages are translated into. Kept in the settings table, so it survives a relaunch and
    /// is the same answer the automatic offer uses.
    var translationTarget: Locale.Language {
        get { settings.translationTarget }
        set { settings.translationTarget = newValue }
    }

    /// The one or two languages worth naming on the button itself — "Translate to Spanish" rather
    /// than "Translate", which makes the reader press it to find out.
    ///
    /// `Locale.preferredLanguages` is the reader's own list in the reader's own order, which is a
    /// better guess than the single system language: someone reading Russian pages on an English
    /// Mac has said so there. What the page is already written in is dropped — offering to
    /// translate a Russian page into Russian is the offer that made this necessary — and so is
    /// anything this Mac cannot translate into.
    func suggestedTargets(excluding source: Locale.Language?) -> [Locale.Language] {
        let supported = appleTranslator.languages
        let sourceCode = source?.languageCode?.identifier
        var seen = Set<String>()
        var out: [Locale.Language] = []

        for identifier in Locale.preferredLanguages + [translationTarget.maximalIdentifier, "en"] {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier, code != sourceCode else { continue }
            guard seen.insert(code).inserted else { continue }
            guard supported.isEmpty || supported.contains(where: { $0.languageCode?.identifier == code })
            else { continue }
            // Named on the button means offered, and offered means it works. A pair Apple does not
            // have is not a suggestion — it belongs in the full list, greyed, where the reader who
            // went looking for it is told why rather than left pressing a dead item.
            if let source, appleTranslator.cannotTranslate(from: source, to: language) { continue }
            out.append(language)
            if out.count == 2 { break }
        }
        return out
    }

    /// Sites translated the moment they load, without being asked.
    func alwaysTranslates(_ host: String) -> Bool {
        settings.alwaysTranslateHosts.contains(host)
    }

    func setAlwaysTranslates(_ host: String, _ on: Bool) {
        var hosts = settings.alwaysTranslateHosts
        hosts.removeAll { $0 == host }
        if on { hosts.append(host) }
        settings.alwaysTranslateHosts = hosts
    }

    /// Translate into a language the reader picked, and remember it as the new default — picking one
    /// is how you say what you read, and being asked again next time is not an improvement.
    func translate(_ tab: BrowserTab, to language: Locale.Language) {
        translationTarget = language
        translation.forget(tab.id)
        toggleTranslation(of: tab)
    }

    /// Translate whatever is selected, in the system's own popover.
    ///
    /// Nothing in six can know there *is* a selection before asking the page: `ActivatedElementInfo`
    /// carries a link URL and nothing else, so the page context menu cannot see one, and a menu
    /// cannot await. "Highlight Selection" has the same shape and the same answer — the item is
    /// always enabled, and pressing it with nothing selected says so.
    func translateSelection(of tab: BrowserTab) {
        Task {
            if await translation.readSelection(tab) { return }
            translation.fail(id: tab.id, TranslationLanguage.noSelection, target: translationTarget)
        }
    }

    /// The popover's "replace with translation", for a field where that means something.
    func replaceSelection(in tab: BrowserTab, with text: String) {
        Task {
            _ = try? await tab.runScript(
                "document.execCommand('insertText', false, replacement); return true;",
                arguments: ["replacement": text]
            )
        }
    }

    /// Give up on a run in progress and leave the page as it is — half translated is still
    /// readable, and the alternative is a bar you cannot dismiss.
    func stopTranslating(_ tab: BrowserTab) {
        translation.stop(tab.id)
        translation.markStopped(id: tab.id)
    }

    /// Look at the focused page and translate it, or put it back. One entry point, because that is
    /// what a button and a menu item both want.
    func toggleTranslation(of tab: BrowserTab) {
        let target = settings.translationTarget
        Task {
            if let state = translation[tab.id], state.isTranslated {
                if state.showsOriginal {
                    await translation.showTranslation(tab, id: tab.id)
                } else {
                    await translation.showOriginal(tab, id: tab.id)
                }
                return
            }
            guard let plan = try? await translation.plan(tab) else {
                return translation.fail(id: tab.id, TranslationLanguage.unreadable, target: target)
            }
            if let refusal = plan.refusal {
                return translation.fail(id: tab.id, refusal, target: target)
            }
            guard let source = TranslationLanguage.source(of: plan) else {
                return translation.fail(id: tab.id, TranslationLanguage.undetected, target: target)
            }
            guard TranslationLanguage.isForeign(source, to: target) else {
                return translation.fail(
                    id: tab.id,
                    TranslationLanguage.alreadyInTarget(AppleTranslator.name(of: source)),
                    target: target
                )
            }
            await translation.translate(tab, id: tab.id, from: source, to: target)
        }
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
            tabs: tabs.filter { !privateIDs.contains($0.profileID) }.map(Self.entry(for:)),
            strips: layout.allStrips
                .filter { !privateIDs.contains($0.key) }
                .map { StripSnapshot(profileID: $0.key, strip: $0.value) }
                .sorted { $0.profileID.uuidString < $1.profileID.uuidString },
            research: research.filter { !privateIDs.contains($0.profileID) }
        )
    }

    /// What is kept of one window: its address and title, and — for the two kinds that are not a page
    /// — the document beside it or the question an app window was opened with. Written by the session
    /// snapshot and by `remember`, because a window that can be brought back after a relaunch and one
    /// that can be brought back with ⌘⇧T are the same window described twice.
    private static func entry(for tab: BrowserTab) -> TabSnapshot {
        var entry = TabSnapshot(id: tab.id, profileID: tab.profileID, url: tab.showsStartPage ? nil : tab.currentURL, title: tab.title)
        if let document = tab.document {
            entry.document = DocumentSnapshot(id: document.id, title: document.title, modifiedAt: document.modifiedAt,
                                              fileURL: document.fileURL, showsPreview: document.showsPreview)
        }
        // What an app window keeps is the question, not the answer: which server, which tool, with
        // what. See `AppWindowSnapshot`.
        if let app = tab.app {
            entry.app = app.snapshot
        } else if let pending = tab.pendingApp {
            entry.app = pending // never run this launch; it comes back as it went
        }
        return entry
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
            add(makeTab(from: tab, profile: profile))
        }
        layout.restore(strips: strips)
    }

    /// One window rebuilt from the record kept of it — the session file's, or the one `closeTab` keeps
    /// for ⌘⇧T. Four kinds, in the order that tells them apart; the last is an ordinary page.
    ///
    /// `text` is for the reopened document, whose file under `Documents/` was deleted along with the
    /// window: by the time anyone asks for it back, what `closeTab` kept is the only copy left.
    private func makeTab(from saved: TabSnapshot, profile: Profile, text: String? = nil) -> BrowserTab {
        if let document = saved.document {
            let text = text ?? documents.load(id: document.id) ?? "# \(document.title)\n"
            return makeDocumentTab(id: saved.id, profile: profile,
                                   document: TextDocument(id: document.id, text: text, modifiedAt: document.modifiedAt,
                                                          fileURL: document.fileURL, showsPreview: document.showsPreview))
        }
        if let app = saved.app { return makePendingAppTab(id: saved.id, profile: profile, saved: app) }
        // A `six://…` window comes back as the page it was, not as a window trying to fetch an address
        // WebKit has never heard of.
        if let url = saved.url, let page = BuiltInPage.page(for: url) {
            return makeBuiltInTab(id: saved.id, profile: profile, page: page)
        }
        return makeTab(id: saved.id, profile: profile, restoring: saved.url, title: saved.title)
    }

    /// The profile list as rows, in the order it is shown. A private profile is recorded nowhere —
    /// here as everywhere else, that is the whole of what private means.
    private static func records(of profiles: [Profile]) -> [ProfileRecord] {
        profiles.filter { !$0.isPrivate }.enumerated().map { ProfileRecord($1, ord: $0) }
    }

    /// The table, made equal to the list. Called by every edit to the profiles; the write is small
    /// and immediate, the way a setting's is, because this is identity and not session state.
    private func saveProfiles() {
        profileStore.save(Self.records(of: profiles))
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
        saveProfiles()
        selectProfile(profile.id)
    }

    /// A new name for a profile. The profile's folder on disk is named after it — the bookmarks'
    /// Markdown and the agents' scratchpad live there — so the rename takes the folder with it, or
    /// everything saved under the old name is orphaned.
    func renameProfile(_ id: Profile.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == id }),
              !profiles[index].isPrivate,
              profiles[index].name != trimmed else { return }
        let old = profiles[index].folder
        profiles[index].name = trimmed
        saveProfiles()
        let new = profiles[index].folder
        guard old != new, FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: old, to: new)
    }

    /// The profile's colour — the tint of the whole window while it is the one on screen.
    func setProfileColor(_ id: Profile.ID, hex: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles[index].colorHex != hex else { return }
        profiles[index].colorHex = hex
        saveProfiles()
    }

    func removeProfile(_ id: Profile.ID) {
        guard profiles.count > 1, let profile = profiles.first(where: { $0.id == id }) else { return }
        for tab in tabs(in: id) { closeTab(tab.id) }
        research.removeAll { $0.profileID == id }
        profiles.removeAll { $0.id == id }
        saveProfiles()
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
        saveProfiles()
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
    func newTab(url: URL? = nil, in profileID: Profile.ID? = nil, on side: NiriPlacement = .right) -> BrowserTab {
        newTab(url: url, in: profileID, workspace: nil, activate: true, on: side)
    }

    /// Opens a window in a specific workspace of a profile's strip. With `activate` off (an agent adding
    /// windows in the background) nothing on screen changes — not even the profile.
    @discardableResult
    func newTab(url: URL?, in profileID: Profile.ID?, workspace: Int?, activate: Bool,
                on side: NiriPlacement = .right) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = makeTab(profile: profile)
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate, on: side)
        }
        if activate { syncSelection() }
        if let url { tab.load(url) }
        return tab
    }

    private func makeTab(id: UUID = UUID(), profile: Profile, restoring url: URL? = nil, title: String = "") -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, dataStore: dataStore(for: profile), restoring: url, title: title)
        // `six://apps` typed into any window's address field shows the page rather than asking
        // WebKit to fetch an address it has never heard of.
        tab.onBuiltInAddress = { [weak self] _, page in self?.openBuiltIn(page) }
        tab.onNavigation = { [weak self] tab, outcome in
            guard let self, let page = tab.livePage, let url = page.url else { return }
            switch outcome {
            case .committed:
                // Before `.finished`, so the old page's batches are dead before the new page is
                // looked at. A private window translates like any other — the work never leaves it.
                self.translation.forget(tab.id)
                if !profile.isPrivate { history.record(url, title: page.title, in: tab.profileID) }
            case .finished:
                // Above the private guard, deliberately. A private window keeps no history and
                // stores no highlights, but a page in another language is still a page in another
                // language — and translating it never leaves the machine, so there is nothing for
                // the profile to protect it from.
                offerTranslation(of: tab)
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
        // Remembered so the column can be taken back — and this one handed the focus back — if the
        // link turns out to be a file. See `closeIfOnlyCarriedALink`.
        opened.openedFrom = tab.id
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
    /// And the focus goes back to the window the link was clicked in, which `closeTab` alone will not
    /// do: closing a column focuses whatever slides into its place, and what slides into this one's
    /// place is the window that happened to be to its right. That is right for ⌘W — the strip closes
    /// up and the eye carries on the way it was going — and wrong here, where nothing was read and
    /// nothing was meant to be left behind. With no window right of the link there was nothing to
    /// slide in and the two rules agreed, which is why this only ever went wrong sometimes.
    ///
    /// A download asked for from a page the user is reading leaves that page alone, and so does one
    /// asked for in a window that had already shown something.
    private func closeIfOnlyCarriedALink(_ tab: BrowserTab) {
        guard let opener = tab.openedFrom, !tab.hasCommitted else { return }
        // Not here: this runs inside the policy decision that turned the link into a download, and
        // the page is still waiting for the answer to it. One turn later there is nothing to unwind.
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let tab, !tab.hasCommitted else { return }
            let wasFocused = selectedTabID == tab.id
            closeTab(tab.id)
            // Only when the eye was in the window being closed. A link opened behind (⌘-click) never
            // had the focus, and taking it to the opener would move a reader who never left it.
            guard wasFocused, tabsByID[opener] != nil else { return }
            selectTab(opener)
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
        #elseif os(iOS)
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

    // MARK: Six's own pages

    /// Shows one of six's own pages (`six://apps`) — the one that is already open in this profile if
    /// there is one, otherwise a new column beside the focus.
    ///
    /// Focusing rather than opening a second is the difference between a page and a panel: a person
    /// who asks for the server list twice wants the list, not two of them.
    @discardableResult
    func openBuiltIn(_ page: BuiltInPage, in profileID: Profile.ID? = nil) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        if let existing = tabs(in: profile.id).first(where: { $0.builtIn == page }) {
            selectTab(existing.id)
            return existing
        }
        let tab = makeBuiltInTab(profile: profile, page: page)
        add(tab)
        if selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: nil, focus: true)
        }
        syncSelection()
        return tab
    }

    private func makePendingAppTab(id: UUID, profile: Profile, saved: AppWindowSnapshot) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, pendingApp: saved)
        tab.onBuiltInAddress = { [weak self] _, page in self?.openBuiltIn(page) }
        return tab
    }

    /// Swaps a window's contents in place, keeping its id — so the column it sits in, and the place
    /// that column has in the strip, do not move. What a restored app becomes when it runs again.
    func replaceWithApp(_ tabID: BrowserTab.ID, session: MCPAppSession) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let old = tabs[index]
        let tab = BrowserTab(id: tabID, profileID: old.profileID, app: session)
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        session.onOpenLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.open(url, from: tab)
        }
        old.close()
        tabs[index] = tab
        tabsByID[tabID] = tab
        tab.cache = pages
        tab.thumbnails = thumbnails
        tab.blocker = blocker
        tab.extensions = extensions
        tab.pageControllers = pageControllers
        tab.devTools = devTools
        tab.permissions = permissions
        if selectedTabID == tabID { syncSelection() }
    }

    private func makeBuiltInTab(id: UUID = UUID(), profile: Profile, page: BuiltInPage) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, builtIn: page)
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        tab.onBuiltInAddress = { [weak self] _, page in self?.openBuiltIn(page) }
        return tab
    }

    // MARK: Apps

    /// Opens an MCP app — a window of the strip drawing a tool's result with the server's own HTML.
    /// Same placement rules as `newTab`; see [mcp-apps.md](../../docs/mcp-apps.md).
    @discardableResult
    func newApp(_ session: MCPAppSession, in profileID: Profile.ID? = nil, workspace: Int? = nil,
                activate: Bool = true) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = BrowserTab(id: UUID(), profileID: profile.id, app: session)
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        // `ui/open-link`: the app asked for a page, and a page in six is a window beside it.
        session.onOpenLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.open(url, from: tab)
        }
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
        tab.onBuiltInAddress = { [weak self] _, page in self?.openBuiltIn(page) }
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
        // Before anything is taken apart: `remember` reads where the column stands and what a
        // document window is holding, and both are gone by the end of this function.
        remember(closed)
        // Before the page goes, not after: `ui/resource-teardown` is a question asked of code that
        // has to still be running to answer it. The session holds the page for as long as that
        // takes, up to a second.
        closed.app?.windowClosed()
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

    // MARK: Putting a closed window back

    /// How many closed windows are held for ⌘⇧T. Deep enough to undo a run of ⌘W, and bounded at all
    /// because nothing else ever clears the list: what is kept is a description of a window rather
    /// than the window, so it costs little, but a browser open for a week should not go on
    /// accumulating every window it has ever had.
    static let rememberedWindows = 10

    /// Is there anything for ⌘⇧T to put back? Only ever a guess at the menu item: the profile a
    /// remembered window belongs to can be deleted while it waits, and `reopenClosedWindow` is the
    /// one that finds out.
    var canReopenClosedWindow: Bool { !closedWindows.isEmpty }

    /// Keeps what a closed window was, so ⌘⇧T can build it again. The record is the session
    /// snapshot's (`entry(for:)`), plus where in the strip the window stood.
    ///
    /// Two kinds are not kept. A private window leaves nothing behind — not on disk, and not in a
    /// list in memory either; that is the whole of what the profile promises. And a window that never
    /// showed anything is nothing to put back: a start page closed with ⌘W, or the window a link
    /// opened that turned out to be a download (`closeIfOnlyCarriedALink`) and would otherwise push
    /// the window somebody actually wants off the end of the list.
    private func remember(_ tab: BrowserTab) {
        guard !isPrivate(tab.profileID) else { return }
        let entry = Self.entry(for: tab)
        guard entry.url != nil || entry.document != nil || entry.app != nil else { return }
        guard let place = layout.location(ofTabID: tab.id, in: tab.profileID) else { return }
        // The document's text, before `closeTab` deletes the file holding it.
        closedWindows.append(ClosedWindow(tab: entry, workspace: place.workspace, index: place.index,
                                          text: tab.document?.text))
        if closedWindows.count > Self.rememberedWindows { closedWindows.removeFirst() }
    }

    /// ⌘⇧T. The last window closed comes back where it stood, showing what it showed, and takes the
    /// focus — it was asked for, so it is the one being looked at.
    ///
    /// The loop is for the windows that cannot come back: a profile deleted since takes its windows
    /// with it (`closeProfile` closes them one by one, and each is remembered), and those are not
    /// keystrokes that should do nothing. It walks past them to the last window that still can.
    func reopenClosedWindow() {
        while let closed = closedWindows.popLast() {
            guard let profile = profiles.first(where: { $0.id == closed.tab.profileID }) else { continue }
            let tab = makeTab(from: closed.tab, profile: profile, text: closed.text)
            add(tab)
            if selectedProfileID != profile.id {
                selectedProfileID = profile.id
                layout.activeProfileID = profile.id
            }
            withAnimation(NiriLayout.switchAnimation) {
                layout.restoreColumn(tabID: tab.id, in: profile.id, workspace: closed.workspace, at: closed.index)
            }
            syncSelection()
            return
        }
    }

    // MARK: niri operations

    func focusColumn(_ delta: Int) { animateLayout { layout.focusColumn(delta) } }
    func focusColumnEdge(last: Bool) { animateLayout { layout.focusColumnEdge(last: last) } }
    func moveColumn(_ delta: Int) { animateLayout { layout.moveColumn(delta) } }
    func focusWorkspace(_ delta: Int) { animateLayout { layout.focusWorkspace(delta) } }
    func focusWorkspace(at index: Int) { animateLayout { layout.focusWorkspace(at: index) } }
    func moveColumnToWorkspace(_ delta: Int) { animateLayout { layout.moveColumnToWorkspace(delta) } }

    // MARK: Carrying a window across the overview

    /// Picked up. Deliberately un-animated from here on: the card follows the pointer, and a card that
    /// eases towards the pointer is a card that is never quite under it. What *is* animated is the gap
    /// the rest of the row opens up, and the views do that off the target the drag is reporting.
    func beginColumnDrag(tabID: BrowserTab.ID) {
        layout.beginColumnDrag(tabID: tabID)
    }

    func updateColumnDrag(translation: CGSize) {
        layout.updateColumnDrag(translation: translation)
    }

    /// Let go. The window lands where the gap was, and the focus goes with it — a window dropped into
    /// another row that left the view behind in the old one would be a window you have just lost.
    func endColumnDrag() {
        var moved = false
        withAnimation(NiriLayout.switchAnimation) { moved = layout.commitColumnDrag() }
        if moved { syncSelection() }
    }

    func cancelColumnDrag() {
        withAnimation(NiriLayout.switchAnimation) { layout.cancelColumnDrag() }
    }

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

    func togglePeeksAtEdges() {
        peeksAtEdges.toggle()
        settings.peeksAtEdges = peeksAtEdges
        // Turned off with the strip mid-lean — the pointer is resting on a button that is about to
        // stop taking peeks, and nothing would ever tell it to let go.
        if !peeksAtEdges { withAnimation(NiriLayout.peekAnimation) { layout.edgeHover = 0 } }
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
        layout.cancelColumnDrag() // a window in the hand is put back where it was, not carried out
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

/// A window that was closed, kept whole enough to be built again by ⌘⇧T.
///
/// `TabSnapshot` is the record the session file keeps, so a reopened window comes back the way a
/// relaunched one does — the same kinds, rebuilt by the same call. What the session file has no use
/// for is the rest: where in the strip the window stood, and a document's text, which lives in a file
/// that goes when the window does.
private struct ClosedWindow {
    var tab: TabSnapshot
    var workspace: Int
    var index: Int
    var text: String?
}
