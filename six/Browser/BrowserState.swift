#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI
import WebKit

/// App-wide browser model: profiles (each with an isolated data store) and tabs across all profiles,
/// arranged by `TilingLayout` into per-profile strips of workspaces.
@MainActor
@Observable
final class BrowserState {
    private(set) var profiles: [Profile]
    private(set) var tabs: [BrowserTab] = []
    var selectedProfileID: Profile.ID
    var selectedTabID: BrowserTab.ID?

    /// Scrollable-tiling layout: the focused column here is the selected tab.
    let layout = TilingLayout()
    /// The app-wide budget for live `WebPage`s — one queue across every profile and every workspace,
    /// which is what makes stepping out of a workspace and back cheap. See `LivePageCache`.
    let pages = LivePageCache()
    /// The pictures of the windows, kept as files so the overview is not blank after a relaunch.
    @ObservationIgnored let thumbnails = PageThumbnails()
    /// The sites' own little pictures, by host.
    let siteIcons = SiteIcons()
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
    /// What each window has selected, or a caret in — the assistant's context; wired at launch.
    @ObservationIgnored var pageFocus: PageFocusStore? {
        didSet { for tab in tabs { tab.pageFocus = pageFocus } }
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
    /// The order the windows were last looked at, and the ring ⌃Tab walks (`WindowSwitcher`).
    let switcher = WindowSwitcher()
    /// Translating a page in place, and the engine that does it. Both are `@Observable` themselves,
    /// so the reference can be ignored here while the views still see them change.
    @ObservationIgnored let translation = PageTranslator()
    /// ⌘F, per window. `@Observable` itself, like `translation` above.
    @ObservationIgnored let find = PageFinder()
    /// Apple's on-device translator. Held by name as well as behind the protocol, because the
    /// hidden `.translationTask` host needs the concrete one — that is the whole point of it.
    @ObservationIgnored let appleTranslator = AppleTranslator()
    /// Deep-research runs (see `ResearchRun`).
    var research: [ResearchRun] = []
    /// Windows that were closed, oldest first — what ⌘⇧T puts back. Observed rather than ignored so
    /// the menu item can go grey the moment the last one is used up.
    private var closedWindows: [ClosedWindow] = []
    /// Whether the strip's edge buttons wait to be found or stand on the screen (`ConfigurationStore`).
    /// Chrome rather than geometry, so it lives here and not in `TilingLayout`: it changes nothing a
    /// second front end would have to agree with, only whether this one asks for a peek.
    var peeksAtEdges = ConfigurationStore.peeksByDefault
    /// The row, or a tab bar over one page (`InterfaceStyle`). Here and not in `TilingLayout` for
    /// the reason `peeksAtEdges` is: it is how this front draws the strip, not a fact about the strip.
    private(set) var interfaceStyle: InterfaceStyle = .tabs
    /// Tabs picked together in the tab bar with ⌘ and ⇧ — what the tab menu acts on when it is
    /// opened on one of them. The tab in front is always among them; anything that moves it
    /// elsewhere without a click starts the pick again from there (`syncSelection`).
    private(set) var pickedTabs: Set<UUID> = []
    /// Where a ⇧-click's range starts: the tab last clicked without ⇧.
    @ObservationIgnored private var pickAnchor: UUID?
    var showsTabs: Bool { interfaceStyle == .tabs }
    @ObservationIgnored private let settings: ConfigurationStore
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
    init(snapshot: BrowserSnapshot? = nil, history: HistoryStore, settings: ConfigurationStore,
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
        layout.setFill(settings.fill)
        peeksAtEdges = settings.peeksAtEdges
        interfaceStyle = settings.interfaceStyle
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
        // A browser that has been used before comes back as it was left, an empty row included: the
        // strip offers "New Window" and waits, the same as it does the moment the last window is
        // closed. Only a browser with nothing to restore opens the first window itself.
        if layout.hasColumns || snapshot != nil { syncSelection() } else { newTab() }
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

    /// True while the overview is up, so entering it can be told from moving around inside it.
    @ObservationIgnored private var showingOverview = false

    private func refreshLivePages() {
        let visible = layout.visibleTabIDs
        // On the way into the overview every window on screen has just become a card. Its picture was
        // taken before the overview opened (`toggleOverview`): by now its web view is gone.
        if layout.isOverview, !showingOverview {
            // The rest of the strip is about to be drawn as cards: the ones with no picture in memory
            // — never shown this launch, or dropped for the budget — read theirs off disk. Only this
            // profile's: the overview shows one strip, and the others are not on screen to be drawn.
            for tab in tabs(in: selectedProfileID) { tab.loadPictureIfNeeded() }
        }
        showingOverview = layout.isOverview
        // Each window's own width, so the picture taken of it is the shape of the column it fills —
        // or of the half of it, which is where a split's pictures come out narrow and right rather
        // than wide and stretched.
        if let workspace = layout.focusedWorkspace {
            let frames = layout.columnFrames(workspace)
            for (index, column) in workspace.columns.enumerated() where frames.indices.contains(index) {
                let panes = layout.paneFrames(column, in: frames[index])
                for (pane, id) in column.tabIDs.enumerated() where visible.contains(id) && panes.indices.contains(pane) {
                    tabsByID[id]?.displaySize = panes[pane].size
                }
            }
        }
        // Only the focused window is loaded. Everything else on screen is pinned — a neighbour that
        // still has its page goes on showing it — but nothing is built for walking past it, and the
        // overview builds nothing at all. The focused *column*, because both halves of a split are
        // the window you are looking at.
        let building = layout.isOverview ? [] : (layout.focusedWorkspace?.focusedColumn?.tabIDs ?? [])
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
            research: research.filter { !privateIDs.contains($0.profileID) },
            downloads: downloads.unfinished.filter { !privateIDs.contains($0.profileID ?? selectedProfileID) }
        )
    }

    /// How far back a window's trail is written down. WebKit's own list is bounded too, and the
    /// snapshot is read and written on every change: a browser open for a week should not be
    /// carrying every address it has ever shown in a file it rewrites once a second.
    static let rememberedSteps = 50

    /// What is kept of one window: its address and title, where it has been, and — for the two kinds
    /// that are not a page — the document beside it or the question an app window was opened with. Written by the session
    /// snapshot and by `remember`, because a window that can be brought back after a relaunch and one
    /// that can be brought back with ⌘⇧T are the same window described twice.
    private static func entry(for tab: BrowserTab) -> TabSnapshot {
        var entry = TabSnapshot(id: tab.id, profileID: tab.profileID, url: tab.showsStartPage ? nil : tab.currentURL, title: tab.title)
        // Where it has been, so ⌘[ still works after a relaunch. Bounded: a window read all day
        // accumulates hundreds of addresses, and nobody walks back through hundreds.
        let trail = tab.trail
        if !trail.back.isEmpty { entry.back = trail.back.suffix(Self.rememberedSteps) }
        if !trail.forward.isEmpty { entry.forward = Array(trail.forward.prefix(Self.rememberedSteps)) }
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
        var strips: [UUID: TilingStrip] = [:]
        var placed = Set<UUID>()
        for entry in snapshot.strips where profileIDs.contains(entry.profileID) {
            var strip = entry.strip
            for i in strip.workspaces.indices {
                strip.workspaces[i].columns = strip.workspaces[i].columns.compactMap { column in
                    // A split can have lost either half — a window whose profile is gone, a record
                    // that never reached the file, one already placed by a row above. The half that
                    // is still there keeps the column and fills it; both gone takes it with them.
                    let kept = column.tabIDs.filter { id in
                        guard let tab = saved[id], tab.profileID == entry.profileID, !placed.contains(id) else { return false }
                        placed.insert(tab.id)
                        return true
                    }
                    guard let first = kept.first else { return nil }
                    var rebuilt = column
                    rebuilt.tabID = first
                    rebuilt.second = kept.count > 1 ? kept[1] : nil
                    rebuilt.pane = rebuilt.paneIndex(of: column.focusedTabID) ?? 0
                    return rebuilt
                }
            }
            strips[entry.profileID] = strip
        }
        for tab in snapshot.tabs where placed.contains(tab.id) {
            guard let profile = profiles.first(where: { $0.id == tab.profileID }) else { continue }
            add(makeTab(from: tab, profile: profile))
        }
        layout.restore(strips: strips)
        downloads.restore(snapshot.downloads ?? [])
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
        if let url = saved.url, let parsed = BuiltInPage.parse(url) {
            let tab = makeBuiltInTab(id: saved.id, profile: profile, page: parsed.page)
            // The rest of the path came back with the address, so the page opens where it was left.
            tab.section = parsed.section
            return tab
        }
        let tab = makeTab(id: saved.id, profile: profile, restoring: saved.url, title: saved.title)
        // The same trail a window handed to another profile is given, from the file instead of from
        // the window it replaces. Not the scroll offset: it is only read when a window leaves the
        // screen, so for one that never did it would be an offset from the start of the session.
        if saved.back?.isEmpty == false || saved.forward?.isEmpty == false {
            tab.adopt(BrowserTab.Trail(back: saved.back ?? [], forward: saved.forward ?? []))
        }
        return tab
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

    /// A profile whose row is empty stays empty when it comes up, for the same reason `closeTab`
    /// leaves one empty: otherwise stepping away to another profile and back would put the start page
    /// right back where ⌘W had just taken it from.
    func selectProfile(_ id: Profile.ID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        layout.activeProfileID = id
        syncSelection()
    }

    /// A profile just made is a different matter: it was asked for, and it is asked for in order to
    /// browse in it, so it opens with a window the way a new browser does.
    func addProfile(name: String, colorHex: String) {
        let profile = Profile(name: name, colorHex: colorHex)
        profiles.append(profile)
        saveProfiles()
        selectProfile(profile.id)
        newTab(in: profile.id)
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
        connect(tab)
        extensions?.noteOpened(tab)
        tabs.append(tab)
        tabsByID[tab.id] = tab
    }

    /// The app-wide things a window draws on, handed to it in one place. Every window gets them,
    /// including the ones built to take another's place — an app that has started running
    /// (`replaceWithApp`), a window moved to another profile (`moveTab(_:toProfile:)`) — which is why
    /// this is not simply the top of `add`: those two keep the window's id and its place in `tabs`,
    /// so they wire the window up without adding it.
    private func connect(_ tab: BrowserTab) {
        tab.cache = pages
        tab.thumbnails = thumbnails
        // None for a private window: an icon is a file saying a host was visited.
        tab.siteIcons = isPrivate(tab.profileID) ? nil : siteIcons
        tab.blocker = blocker
        tab.extensions = extensions
        tab.pageControllers = pageControllers
        tab.devTools = devTools
        tab.pageFocus = pageFocus
        tab.permissions = permissions
    }

    func tabs(in profileID: Profile.ID) -> [BrowserTab] {
        tabs.filter { $0.profileID == profileID }
    }

    @discardableResult
    func newTab(url: URL? = nil, in profileID: Profile.ID? = nil, on side: TilingPlacement = .right) -> BrowserTab {
        newTab(url: url, in: profileID, workspace: nil, activate: true, on: side)
    }

    /// Opens a window in a specific workspace of a profile's strip. With `activate` off (an agent adding
    /// windows in the background) nothing on screen changes — not even the profile.
    @discardableResult
    func newTab(url: URL?, in profileID: Profile.ID?, workspace: Int?, activate: Bool,
                on side: TilingPlacement = .right) -> BrowserTab {
        // One of six's own addresses is one of six's own pages, however it arrives — typed, handed
        // over by another app, or asked for by an agent's `open_window`. Without this the window is
        // built as a web one, `onBuiltInAddress` fires on the way to loading it, and the person is
        // left with the page they asked for *and* an empty window beside it.
        if let url, let parsed = BuiltInPage.parse(url) {
            return openBuiltIn(parsed.page, section: parsed.section, in: profileID, activate: activate)
        }
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = makeTab(profile: profile)
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(TilingLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate, on: side)
        }
        if activate { syncSelection() }
        if let url {
            tab.load(url)
        } else {
            #if os(macOS)
            // A blank window is the start page's, unless the user has let an installed extension
            // stand in for it (`WKWebExtension.hasOverrideNewTabPage`) — checked fresh, not assumed
            // from the setting alone, since uninstalling the extension does not clear it.
            if let override = extensions?.overrideNewTabPageURL(for: profile.id) { tab.load(override) }
            #endif
        }
        return tab
    }

    private func makeTab(id: UUID = UUID(), profile: Profile, restoring url: URL? = nil, title: String = "") -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, dataStore: dataStore(for: profile), restoring: url, title: title)
        // `six://configuration` typed into any window's address field shows the page rather than asking
        // WebKit to fetch an address it has never heard of.
        tab.onBuiltInAddress = { [weak self] _, page, section in self?.openBuiltIn(page, section: section) }
        tab.onNavigation = { [weak self] tab, outcome in
            guard let self, let page = tab.livePage, let url = page.url else { return }
            switch outcome {
            case .committed:
                // Before `.finished`, so the old page's batches are dead before the new page is
                // looked at. A private window translates like any other — the work never leaves it.
                self.translation.forget(tab.id)
                self.find.forget(tab.id) // a page gone is a page whose matches went with it
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
        guard url.scheme != nil else { return }
        // mailto:, tel:, magnet:, a custom scheme — the system's business, not a column's.
        guard !ExternalScheme.isExternal(url) else {
            ExternalScheme.open(url)
            return
        }
        let opened = newTab(url: url, in: tab.profileID, workspace: nil, activate: !background)
        // Remembered so the column can be taken back — and this one handed the focus back — if the
        // link turns out to be a file. See `closeIfOnlyCarriedALink`.
        opened.openedFrom = tab.id
        // Only for the ones that go behind: a window that comes forward takes the eye with it and
        // needs no announcing. The one that does not is otherwise invisible — see `TilingLayout.peek`.
        if background { layout.peek() }
    }


    /// Download Linked File, `<a download>`, or a response no page can show.
    func download(_ request: URLRequest, suggestedName: String?, from tab: BrowserTab) {
        let profile = profiles.first { $0.id == tab.profileID } ?? selectedProfile
        downloads.start(request, suggestedName: suggestedName, referrer: tab.currentURL,
                        profileID: profile.id, cookies: dataStore(for: profile))
        flights.launch(from: Self.clickInWindow)
        closeIfOnlyCarriedALink(tab)
    }

    /// Picks a stopped download up again. Here rather than on the store because only the browser
    /// knows whose cookies to use: a row restored from the last session has no request left, and the
    /// one built for it is built with the profile's cookies as they are now.
    func resumeDownload(_ id: DownloadStore.Item.ID) {
        guard let item = downloads.items.first(where: { $0.id == id }) else { return }
        let profile = item.profileID.flatMap { id in profiles.first { $0.id == id } } ?? selectedProfile
        downloads.resume(id, cookies: dataStore(for: profile))
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
            // Not remembered: nobody asked for this window and nobody asked for it to go, so there is
            // nothing here to undo, and it would push a window somebody does want off the end of the
            // list.
            closeTab(tab.id, remembering: false)
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
        withAnimation(TilingLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate)
        }
        if activate { syncSelection() }
        return tab
    }

    // MARK: Six's own pages

    /// Shows one of six's own pages (such as `six://configuration`) — the one that is already open
    /// in this profile if there is one, otherwise a new column beside the focus.
    ///
    /// Focusing rather than opening a second is the difference between a page and a panel: a person
    /// who asks for the server list twice wants the list, not two of them.
    @discardableResult
    /// `section` is the pane and its tab (`six://configuration/assistant#agents`): a page that is
    /// already open is turned to that part rather than left where it was, which is what a button
    /// saying "Set Up…" promises.
    func openBuiltIn(_ page: BuiltInPage, section: String? = nil, in profileID: Profile.ID? = nil,
                     activate: Bool = true) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        // A chat is one page per conversation: the one already open is focused, another opens beside.
        if let existing = tabs(in: profile.id).first(where: { $0.builtIn == page && (!page.isPerSection || $0.section == section) }) {
            if let section { existing.section = section }
            if activate { selectTab(existing.id) }
            return existing
        }
        let tab = makeBuiltInTab(profile: profile, page: page)
        tab.section = section
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(TilingLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: nil, focus: activate)
        }
        if activate { syncSelection() }
        return tab
    }

    private func makePendingAppTab(id: UUID, profile: Profile, saved: AppWindowSnapshot) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, pendingApp: saved)
        tab.onBuiltInAddress = { [weak self] _, page, section in self?.openBuiltIn(page, section: section) }
        return tab
    }

    /// Swaps a window's contents in place, keeping its id — so the column it sits in, and the place
    /// that column has in the strip, do not move. What a restored app becomes when it runs again.
    func replaceWithApp(_ tabID: BrowserTab.ID, session: MCPAppSession) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let old = tabs[index]
        let tab = makeAppTab(id: tabID, profileID: old.profileID, session: session)
        old.close()
        tabs[index] = tab
        tabsByID[tabID] = tab
        connect(tab)
        if selectedTabID == tabID { syncSelection() }
    }

    private func makeBuiltInTab(id: UUID = UUID(), profile: Profile, page: BuiltInPage) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, builtIn: page)
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        tab.onBuiltInAddress = { [weak self] _, page, section in self?.openBuiltIn(page, section: section) }
        return tab
    }

    // MARK: Apps

    /// Opens an MCP app — a window of the strip drawing a tool's result with the server's own HTML.
    /// Same placement rules as `newTab`; see [mcp-apps.md](../../docs/mcp-apps.md).
    @discardableResult
    func newApp(_ session: MCPAppSession, in profileID: Profile.ID? = nil, workspace: Int? = nil,
                activate: Bool = true) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = makeAppTab(profileID: profile.id, session: session)
        add(tab)
        if activate, selectedProfileID != profile.id {
            selectedProfileID = profile.id
            layout.activeProfileID = profile.id
        }
        withAnimation(TilingLayout.switchAnimation) {
            layout.insertColumn(tabID: tab.id, in: profile.id, workspace: workspace, focus: activate)
        }
        if activate { syncSelection() }
        return tab
    }

    /// An app window. The profile is an id and not a `Profile` because that is all an app window
    /// needs: it is served from six's own scheme and borrows nobody's store.
    private func makeAppTab(id: UUID = UUID(), profileID: Profile.ID, session: MCPAppSession) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profileID, app: session)
        tab.onDocumentLink = { [weak self] tab, url in self?.open(url, from: tab) }
        // `ui/open-link`: the app asked for a page, and a page in six is a window beside it.
        session.onOpenLink = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.open(url, from: tab)
        }
        return tab
    }

    private func makeDocumentTab(id: UUID = UUID(), profile: Profile, document: TextDocument) -> BrowserTab {
        let tab = BrowserTab(id: id, profileID: profile.id, document: document)
        tab.onBuiltInAddress = { [weak self] _, page, section in self?.openBuiltIn(page, section: section) }
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
        withAnimation(TilingLayout.switchAnimation) {
            layout.moveColumn(tabID: id, in: tab.profileID, toWorkspace: index)
        }
        syncSelection()
    }

    /// Moves a window to another profile: the same page, opened as somebody else.
    ///
    /// A rebuild rather than a hand-over, because it cannot be anything else — a page's data store is
    /// fixed when the page is built, so the window is taken apart and one built against the other
    /// profile's store takes its place, keeping its id (`replaceWithApp` does the same for an app
    /// window that starts running). Everything keyed by that id goes on pointing at the same window,
    /// because it is the same window: the ⌃Tab ring, a research run holding it as a source, the
    /// picture of it on disk, the document beside it. It is not remembered for ⌘⇧T either — nothing
    /// was closed.
    ///
    /// What it does not keep is what the profile it left had given it: the cookies and the logins,
    /// the extensions, the blocker's rules its content controller was built with, the answers that
    /// profile's sites had been given, and its highlights. That is the whole point of the move — the
    /// page comes back as the other profile sees it, which usually means signed in as somebody else
    /// or not at all. From then on the visit is that profile's history and nothing of it is written
    /// under the old one; a page moved *out* of a private profile is recorded from the moment it
    /// lands, which is what asking for it in a profile that keeps history means.
    ///
    /// The focus follows the window. Every other move leaves something to look at; this one would
    /// take the column out of the row and leave the person in front of the profile it left, with
    /// nothing on screen to say where it went.
    ///
    /// The one window that will not go is a document about to enter a private profile: its text is a
    /// file under `Documents/`, watched and written a second after every keystroke, and a private
    /// profile is the one that is written down nowhere. Nothing here may quietly delete a person's
    /// document to keep that promise, so the move is refused instead.
    @discardableResult
    func moveTab(_ id: BrowserTab.ID, toProfile profileID: Profile.ID) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              let profile = profiles.first(where: { $0.id == profileID }),
              tabs[index].profileID != profileID,
              canMove(tabs[index], to: profile) else { return nil }
        let old = tabs[index]
        let source = old.profileID
        let trail = old.trail
        // Taken apart before its replacement is built, because both answer to the same id: the new
        // page must be configured with a controller of its own — the old one carries the rules and
        // the hooks the old profile's window was given — and nothing keyed by the id may be left
        // holding the window that went. `close()` is deliberately not called: it would take the
        // picture off disk, and the picture is still a picture of this window.
        extensions?.noteClosed(old)
        old.discard()
        pages.forget(id)
        blocker?.forget(id)
        devTools?.forget(id)
        pageFocus?.forget(id)
        pageControllers.forget(id)
        let tab = rebuilt(old, in: profile)
        tab.adopt(trail)
        connect(tab)
        // The picture came along with the trail, so the budget that lets go of the oldest ones has to
        // be told about it — otherwise this is the one window whose picture nothing ever reclaims.
        if tab.thumbnail != nil { pages.notePicture(tab) }
        extensions?.noteOpened(tab)
        // In place, so the window keeps its position in everything that walks `tabs` in order.
        tabs[index] = tab
        tabsByID[id] = tab
        if let document = tab.document, !profile.isPrivate { documents.save(document) }
        selectedProfileID = profile.id
        layout.activeProfileID = profile.id
        // Unanimated, for the reason `TilingLayout.unanimated` gives: the column leaves one strip and
        // joins another in the same update, and a removal transition would leave two `WebView`s over
        // the one `WebPage` this window is about to build — which traps inside WebKit's SwiftUI half.
        withTransaction(Transaction(animation: nil)) {
            layout.removeColumn(tabID: id, from: source)
            layout.insertColumn(tabID: id, in: profile.id, focus: true)
        }
        syncSelection()
        return tab
    }

    /// Can this window go to that profile? Only the document-into-private refusal above; everything
    /// else moves. Read by the menus, so an item that would do nothing is not offered.
    func canMove(_ tab: BrowserTab, to profile: Profile) -> Bool {
        tab.profileID != profile.id && !(tab.isDocument && profile.isPrivate)
    }

    /// The same window, built against another profile — the kinds `makeTab(from:profile:)` knows and
    /// the one it does not, a *running* app, which moves as itself: nothing here is read back from
    /// disk or asked for again, so a move costs neither a reload of the document's text nor a restart
    /// of the app's session.
    private func rebuilt(_ tab: BrowserTab, in profile: Profile) -> BrowserTab {
        if let document = tab.document { return makeDocumentTab(id: tab.id, profile: profile, document: document) }
        if let session = tab.app { return makeAppTab(id: tab.id, profileID: profile.id, session: session) }
        if let pending = tab.pendingApp { return makePendingAppTab(id: tab.id, profile: profile, saved: pending) }
        if let page = tab.builtIn { return makeBuiltInTab(id: tab.id, profile: profile, page: page) }
        return makeTab(id: tab.id, profile: profile, restoring: tab.showsStartPage ? nil : tab.currentURL,
                       title: tab.title)
    }

    func selectTab(_ id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        extensions?.noteActivated(tab)
        if selectedProfileID != tab.profileID {
            selectedProfileID = tab.profileID
            layout.activeProfileID = tab.profileID
        }
        withAnimation(TilingLayout.switchAnimation) {
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

    /// `remembering` is false only for a window the browser closes on the user's behalf rather than at
    /// their word — see `closeIfOnlyCarriedALink`. Everything a person closes goes on the list ⌘⇧T
    /// reads, whether or not it had anything in it.
    func closeTab(_ id: BrowserTab.ID, remembering: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        tabsByID[id] = nil
        // Before anything is taken apart: `remember` reads where the column stands and what a
        // document window is holding, and both are gone by the end of this function.
        if remembering { remember(closed) }
        // Before the page goes, not after: `ui/resource-teardown` is a question asked of code that
        // has to still be running to answer it. The session holds the page for as long as that
        // takes, up to a second.
        closed.app?.windowClosed()
        closed.close() // drops its page, its place in the budget and its picture
        blocker?.forget(id)
        switcher.forget(id)
        extensions?.noteClosed(closed)
        devTools?.forget(id)
        pageFocus?.forget(id)
        pageControllers.forget(id)
        find.forget(id)
        if let document = closed.document {
            documents.remove(id: document.id)
            research.removeAll { $0.documentTabID == closed.id }
        }
        let wasActive = closed.profileID == selectedProfileID
        withAnimation(TilingLayout.switchAnimation) {
            layout.removeColumn(tabID: id)
        }
        // Nothing left to fill the screen with: a filled mode would be a blank wall with no way back.
        if layout.fill != .tiled, layout.focusedWorkspace?.isEmpty != false { layout.setFill(.window) }
        guard wasActive else { return }
        // And nothing is opened in its place, not even when that was the last window of the profile.
        // An empty row is a state the strip already draws — the row offers "New Window" in the
        // middle of the screen — and the window ⌘W conjured up instead was one nobody had asked for,
        // standing where the one just closed had stood. It also made the first row behave unlike
        // every other: emptying a row further down leaves the windows above it, so the profile is not
        // empty, so that row got the offer while the top one got a start page.
        syncSelection()
    }

    func closeSelectedTab() {
        if let id = selectedTabID { closeTab(id) }
    }

    // MARK: The address, copied

    /// The window whose address was copied a moment ago, and nothing else: the field draws a tick
    /// while this is its window. A keystroke that copies has no other sign — the pasteboard is not on
    /// screen — and "did that work?" is the whole question a person has after pressing it.
    private(set) var copiedAddress: BrowserTab.ID?
    @ObservationIgnored private var copiedAddressReset: Task<Void, Never>?

    /// ⌃⇧C. The address of the window being read, as it would be pasted — the whole of it, encoded
    /// the way it travels, which is what an address is once it leaves the field that prettifies it.
    ///
    /// False when there is nothing to copy: a start page, a document, an app window. The key then
    /// falls through to whatever else wanted it rather than being swallowed on an empty window.
    @discardableResult
    func copyAddress() -> Bool {
        guard let tab = selectedTab, let url = tab.currentURL else { return false }
        Platform.copy(url.absoluteString)
        copiedAddress = tab.id
        copiedAddressReset?.cancel()
        copiedAddressReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.copiedAddress = nil
        }
        return true
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
    /// A private window is the one kind not kept: it leaves nothing behind — not on disk, and not in
    /// a list in memory either; that is the whole of what the profile promises.
    ///
    /// A window showing nothing but the start page is kept too, though there is nothing in it to
    /// build again. ⌘⇧T is an undo of ⌘W, and a list that quietly skipped the empty ones answered a
    /// run of ⌘W by handing back a page closed several windows earlier — and putting it where the
    /// empty window had stood. The one window that never joins the list is the one nobody closed:
    /// see `closeIfOnlyCarriedALink`, which closes with `remembering: false`.
    private func remember(_ tab: BrowserTab) {
        guard !isPrivate(tab.profileID) else { return }
        let entry = Self.entry(for: tab)
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
            withAnimation(TilingLayout.switchAnimation) {
                layout.restoreColumn(tabID: tab.id, in: profile.id, workspace: closed.workspace, at: closed.index)
            }
            syncSelection()
            return
        }
    }

    // MARK: layout operations

    /// ⌥S. The window next along comes in beside the one being read, or the pair goes back to being
    /// two windows in the row (`TilingLayout.toggleSplit`).
    ///
    /// Deliberately not through `animateLayout`. Every other layout verb moves windows about at a
    /// fixed width; this one *changes* the width of two live pages, and WebKit lays a page out again
    /// at every width an animation passes through — measured at three interim layouts over a third
    /// of a second, each of them a page briefly wider than the box it is in, which is a horizontal
    /// scrollbar you can see. The fill modes gave up their animation for the same reason
    /// (docs/layout.md). `TilingLayout.toggleSplit` refuses an animation from the inside as well, for
    /// the menu items that carry one of their own.
    func toggleSplit() {
        // Not with the tabs up, where a split would be two tabs becoming one page with nothing on
        // screen to say so. The menu hides the item then, but a menu decides that from the focused
        // value, and with nothing focused in the window it falls back to the row's items.
        guard !showsTabs else { return }
        plainLayoutChange { layout.toggleSplit() }
    }

    /// Two named windows into one column, or the ⌥S toggle when only one is named. What
    /// `split_window` calls; the answer is whether the strip changed.
    @discardableResult
    func split(_ id: BrowserTab.ID, with other: BrowserTab.ID?) -> Bool {
        guard let window = tab(id) else { return false }
        guard let other, let second = tab(other) else {
            selectTab(id)
            var changed = false
            plainLayoutChange { changed = layout.toggleSplit() }
            return changed
        }
        // One strip at a time: a column is a place on one profile's row, and two windows from
        // different profiles have no column they could share.
        guard second.profileID == window.profileID else { return false }
        var changed = false
        plainLayoutChange { changed = layout.split(tabID: id, with: other, in: window.profileID) }
        return changed
    }

    /// A link opened as the other half of the window it was clicked in, rather than as a column of
    /// its own behind it. The window is made first and split into place, so it arrives the same way
    /// every other window does and the strip does not have to be told twice.
    @discardableResult
    func openBeside(_ url: URL, from tab: BrowserTab) -> BrowserTab? {
        guard let place = layout.location(ofTabID: tab.id, in: tab.profileID) else { return nil }
        // A column that is already two has nowhere to put a third, so the link opens the way a
        // ⌘-click opens it: a window of its own, behind, with the row leaning over to show it.
        let column = layout.strip(for: tab.profileID).workspaces[place.workspace].columns[place.index]
        guard !column.isSplit else {
            openInNewWindow(url, from: tab, background: true)
            return nil
        }
        // Around the window it was clicked in, whether or not that was the window in front: the new
        // one opens beside the focused column, so the focus goes there first and comes back.
        selectTab(tab.id)
        let opened = newTab(url: url, in: tab.profileID, on: .right)
        plainLayoutChange {
            layout.focus(tabID: tab.id)
            layout.toggleSplit()
        }
        return opened
    }

    func focusColumn(_ delta: Int) { animateLayout { layout.focusColumn(delta) } }
    func focusColumnEdge(last: Bool) { animateLayout { layout.focusColumnEdge(last: last) } }
    func moveColumn(_ delta: Int) { animateLayout { layout.moveColumn(delta) } }
    func focusWorkspace(_ delta: Int) { animateLayout { layout.focusWorkspace(delta) } }
    func focusWorkspace(at index: Int) { animateLayout { layout.focusWorkspace(at: index) } }
    /// ⌥⇧↑/↓ in the layout's two changes, with the rows drawn once between them: first the window in
    /// its new row with the row still where it was, then the slide to it as an update of its own.
    func moveColumnToWorkspace(_ delta: Int) {
        layout.verticalPreview = 0
        layout.horizontalPreview = 0
        guard let landed = layout.carryColumn(toWorkspace: delta) else { return }
        Task { @MainActor in
            // A timer and not the next job on the main queue: that one can still run before the run
            // loop gets round to drawing, and the two changes would be one update again.
            try? await Task.sleep(for: .milliseconds(16))
            animateLayout { layout.focusWorkspace(id: landed) }
        }
    }

    // MARK: Flying between windows (⌃Tab)

    /// One step along the ⌃Tab ring, opening it on the first press.
    ///
    /// **How far the ring reaches is decided by the key that opens it.** `⌃Tab` opens it over every
    /// window of the profile — every workspace, every group — and `⌃⇧Tab` over the row in front of
    /// you only (with the tabs up, the group the tab in front is in). Once it is open the two keys
    /// are forward and back, as they always were. It used to be one row and nothing else, on the
    /// argument that flying out of a workspace is a bigger move than a key looks; in use the window
    /// you were just in is as often in the next workspace as in this one, and the row-only ring is
    /// still one key away. Never another profile: that is a browsing world of its own.
    ///
    /// Opening with `⌃⇧Tab` used to mean "the other way round the ring", which on a ring ordered by
    /// memory is the window you looked at longest ago — the one step nobody takes on purpose.
    ///
    /// Nothing moves while the ring is being walked: the cards are pictures, and the flight happens
    /// once, on the key coming up (`endWindowSwitch`). Walking it live would load a page per window
    /// passed, and the row's whole economy is that you get the page where you land.
    func stepWindowSwitch(_ delta: Int) {
        let opening = !switcher.isOpen
        if opening {
            var opened = false
            withAnimation(.smooth(duration: 0.18)) {
                // With the tabs up a tab is a card of its own, split or not: the tab bar draws the two
                // halves of a column as two tabs, and the ring follows what is on screen.
                let tabs = showsTabs
                opened = switcher.open(delta > 0 ? tabOrder() : rowOrder, current: selectedTabID,
                                       group: { [layout] in tabs ? $0 : layout.columnID(of: $0) ?? $0 })
            }
            guard opened else { return }
            // The pictures the cards are drawn from: the window being read is drawn now, while it
            // still has a page to draw, and the ones whose picture was dropped for the memory budget
            // read theirs back off disk — the same two moves the overview makes on its way in.
            selectedTab?.rememberViewState(force: true)
            for id in switcher.ring { tabsByID[id]?.loadPictureIfNeeded() }
        }
        // The first press always goes to the window before this one: the key that opened the
        // ring has already said how far it reaches, and that is all it said.
        withAnimation(.smooth(duration: 0.2)) { switcher.step(opening ? 1 : delta) }
    }

    /// Whether that window is half of a column, and so drawn at half a card's width.
    ///
    /// The whole of what the ring has to ask about the row, now that a stop is a window and nothing
    /// else: a card is one window, at the width that window has where it stands.
    func ringCardIsHalfWide(_ tabID: UUID) -> Bool {
        !showsTabs && layout.columnMates(of: tabID).count > 1
    }

    /// The arrows, while the ring is up: one card along the row as it is drawn. ⌃Tab's own step is
    /// through memory (`stepWindowSwitch`), and the two have not been the same thing since the row
    /// started being drawn along the row.
    func walkWindowSwitch(_ delta: Int) {
        guard switcher.isOpen else { return }
        withAnimation(.smooth(duration: 0.2)) { switcher.walkRow(delta) }
    }

    /// ⌃ came up: fly to the window the ring landed on.
    func endWindowSwitch() {
        var landing: UUID?
        withAnimation(.smooth(duration: 0.16)) { landing = switcher.commit() }
        guard let id = landing, id != selectedTabID else { return }
        exitOverview() // the ring names one window, and the overview is the view that shows every one
        selectTab(id)
    }

    /// ⎋, or anything else that means the pass is off. The row never moved, so there is nothing to
    /// put back.
    func cancelWindowSwitch() {
        withAnimation(.smooth(duration: 0.16)) { switcher.cancel() }
    }

    /// The windows in the row you are looking at, left to right — the focused workspace's columns
    /// and nothing else; with the tabs up, the same workspace as a group. What `⌃⇧Tab` opens the
    /// ring over (`stepWindowSwitch`); `⌃Tab` opens it over `tabOrder()`, every row of the strip.
    private var rowOrder: [UUID] {
        // Every window, both halves of a split included: the ring collapses them to one stop itself
        // (`WindowSwitcher.open`), and it can only pick the half you were last in if it has been
        // handed both.
        return layout.focusedWorkspace?.columns.flatMap(\.tabIDs) ?? []
    }

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
        withAnimation(TilingLayout.switchAnimation) { moved = layout.commitColumnDrag() }
        if moved { syncSelection() }
    }

    func cancelColumnDrag() {
        withAnimation(TilingLayout.switchAnimation) { layout.cancelColumnDrag() }
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
        if !peeksAtEdges { withAnimation(TilingLayout.peekAnimation) { layout.edgeHover = 0 } }
    }

    /// The overview has been asked for and is waiting on the pictures of the windows on screen.
    @ObservationIgnored private var overviewOpening = false

    /// The overview has closed and the canvas is still zooming back in. Six's own pages stay cards
    /// until it is done: they hold AppKit controls, and those laid out under a scale on its way
    /// somewhere never settle (`ColumnView`, where the card is chosen).
    private(set) var isLeavingOverview = false
    @ObservationIgnored private var overviewExits = 0

    /// Opening waits, for a moment at most, for the windows on screen to have their pictures taken.
    ///
    /// The overview shows every window as a card, so its web view is unmounted the moment the flag
    /// flips — and a page with no view is laid out at WebKit's default 1024×768. A picture taken after
    /// that is a 1024-wide page in the corner of a column-wide rectangle: measured from full window,
    /// 1440×757 asked for, 1024×768 there. Tiled windows got away with it only because their width
    /// did not change on the way in, so the detached page kept the layout it had. So the pictures are
    /// taken first, while the pages are still on screen at their own size, and the overview opens
    /// when they are in — or after `pictureWait`, since a web content process that does not answer
    /// must not be able to hold the overview shut.
    func toggleOverview() {
        // The overview is a picture of the row, and with the tabs up there is no row to take one of.
        guard !showsTabs else { return }
        TilingLayout.trace("toggleOverview (was \(layout.isOverview ? "open" : "closed"))")
        if layout.isOverview {
            exitOverview()
            return
        }
        guard !overviewOpening else { return }
        overviewOpening = true
        let pictures = layout.visibleTabIDs.compactMap { tabsByID[$0]?.rememberViewState(force: true) }
        guard !pictures.isEmpty else { return openOverview() }
        Task { @MainActor [weak self] in
            for picture in pictures { await picture.value }
            self?.openOverview()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pictureWait)
            self?.openOverview()
        }
    }

    /// Snapshots measured at 4–100 ms; a hundred and fifty is still a key press, not a wait.
    private static let pictureWait: Duration = .milliseconds(150)

    /// Whichever comes first, the pictures or the wait; the other finds nothing left to open, even
    /// when the overview has been opened and closed again in between.
    private func openOverview() {
        guard overviewOpening else { return }
        overviewOpening = false
        withAnimation(TilingLayout.switchAnimation) {
            layout.isOverview = true
            layout.recenterStrips() // the overview has its own widths, and a filled window's are not them
        }
    }

    func exitOverview() {
        TilingLayout.trace("exitOverview (isOverview \(layout.isOverview))")
        guard layout.isOverview else { return }
        layout.cancelColumnDrag() // a window in the hand is put back where it was, not carried out
        isLeavingOverview = true
        overviewExits += 1
        let exit = overviewExits
        withAnimation(TilingLayout.switchAnimation, completionCriteria: .removed) {
            layout.isOverview = false
            // Free overview scrolling leaves the offset anywhere, and a row going back to a filled
            // window changes every width on the way out.
            layout.recenterStrips()
        } completion: { [weak self] in
            // Only the latest exit's: one interrupted by opening again and closing again must not
            // end the second one's zoom early.
            guard let self, exit == self.overviewExits else { return }
            self.isLeavingOverview = false
        }
    }

    /// The focused window's video into the floating player, or back out of it.
    ///
    /// Not disabled when there is no video to float: whether a page has one is a question only the
    /// page can answer, the answer changes with every play and pause without telling anyone, and a
    /// menu item that greys itself out on a stale answer is worse than one that does nothing when
    /// pressed on a page of text. The same reason "Translate Selection…" is always live.
    func togglePictureInPicture() {
        selectedTab?.togglePictureInPicture()
    }

    /// The page fills the window under the top bar; the layout's own controls stay where they are.
    func toggleFullWindow() {
        guard !showsTabs else { return } // the tab bar always fills; see `toggleSplit`
        setFill(layout.fill == .window ? .tiled : .window)
    }

    private func setFill(_ value: TilingFill) {
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
        settings.fill = value
        syncSelection()
    }

    /// A layout change that must land in one step, because it changes how wide a live page is.
    /// `toggleSplit` has the account; `setFill` is the other one, and predates this by a long way.
    private func plainLayoutChange(_ body: () -> Void) {
        layout.verticalPreview = 0
        layout.horizontalPreview = 0
        body()
        syncSelection()
    }

    private func animateLayout(_ body: () -> Void) {
        withAnimation(TilingLayout.switchAnimation) {
            layout.verticalPreview = 0
            layout.horizontalPreview = 0
            body()
        }
        syncSelection()
    }

    // MARK: The tab bar

    /// Changes which face the window wears. Nothing about the strip moves: the overview is put away
    /// because the tab bar has none, the ring because it was drawn over the old face, and a strip
    /// left focused on its spare empty row is pointed at a tab instead, since a tab bar has no empty
    /// place to be standing in.
    func setInterfaceStyle(_ style: InterfaceStyle) {
        guard style != interfaceStyle else { return }
        cancelWindowSwitch()
        if style == .tabs {
            if layout.isOverview {
                layout.cancelColumnDrag()
                layout.isOverview = false
                layout.recenterStrips()
            }
        }
        interfaceStyle = style
        settings.interfaceStyle = style
        if style == .tabs { selectTabIfNone() }
    }

    /// The tabs in the order the row draws them: row by row, window by window, a split's two halves
    /// side by side. `skippingCollapsed` leaves out the tabs of a folded group — the ones ⌃Tab and
    /// ⌘1…⌘9 cannot see — except the group the selected tab is in, which is never folded away from
    /// under it.
    func tabOrder(skippingCollapsed: Bool = false) -> [UUID] {
        layout.workspaces.flatMap { workspace -> [UUID] in
            let ids = workspace.columns.flatMap(\.tabIDs)
            if skippingCollapsed, workspace.isFolded, !ids.contains(where: { $0 == selectedTabID }) { return [] }
            return ids
        }
    }

    /// ⌘⇧] and ⌘⇧[ with the tabs up: the next tab along the tab bar, round the end. ⌃Tab is the
    /// ring, over every tab (`rowOrder`); this is the one that goes by where the tabs stand.
    func selectAdjacentTab(_ step: Int) {
        let order = tabOrder(skippingCollapsed: true)
        guard !order.isEmpty else { return }
        let here = selectedTabID.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        let next = ((here + step) % order.count + order.count) % order.count
        selectTab(order[next])
    }

    /// ⌘1…⌘8 is that tab, ⌘9 the last one, as in every browser with tabs.
    func selectTab(atPosition position: Int) {
        let order = tabOrder(skippingCollapsed: true)
        guard !order.isEmpty else { return }
        selectTab(position >= 9 ? order[order.count - 1] : order[min(position, order.count) - 1])
    }

    /// Folds a group, or opens it. Folding the group in front selects a neighbouring tab first,
    /// or opens a new ungrouped one when there is none (Chrome does the same).
    func toggleGroup(_ id: UUID) {
        guard let workspace = layout.workspaces.first(where: { $0.id == id }) else { return }
        let collapsing = !workspace.isCollapsed
        if collapsing, let selected = selectedTabID, workspace.columns.contains(where: { $0.holds(selected) }) {
            let inside = Set(workspace.columns.flatMap(\.tabIDs))
            let order = tabOrder(skippingCollapsed: true)
            let here = order.firstIndex(of: selected) ?? 0
            let after = order[here...].first { !inside.contains($0) }
            let before = order[..<here].last { !inside.contains($0) }
            if let other = after ?? before {
                selectTab(other)
            } else if let spare = layout.workspaces.indices.last, layout.workspaces[spare].isEmpty {
                newTab(url: nil, in: selectedProfileID, workspace: spare, activate: true)
            } else {
                return
            }
        }
        layout.setCollapsed(collapsing, workspace: id)
    }

    /// ⌘T with the tabs up: a new tab at the very end, outside every group.
    func newTabAtEnd() {
        guard let index = ungroupedEnd() else { newTab(); return }
        if let last = layout.workspaces[index].columns.last { layout.focus(tabID: last.focusedTabID) }
        newTab(url: nil, in: selectedProfileID, workspace: index, activate: true)
    }

    func moveTabToEnd(_ id: UUID) {
        guard let index = ungroupedEnd() else { return }
        placeTab(id, inGroup: layout.workspaces[index].id, at: layout.workspaces[index].columns.count)
    }

    private func ungroupedEnd() -> Int? {
        let rows = layout.workspaces
        if let last = rows.lastIndex(where: { !$0.isEmpty }), rows[last].name.isEmpty { return last }
        return rows.indices.last.flatMap { rows[$0].isEmpty ? $0 : nil }
    }

    /// The last tab of a group ungroups it, so no empty named row is left to ask about.
    func removeFromGroup(_ id: UUID) {
        let rows = layout.workspaces
        guard let index = rows.firstIndex(where: { $0.columns.contains { $0.holds(id) } }),
              !rows[index].name.isEmpty else { return }
        if rows[index].columns.flatMap(\.tabIDs).count == 1 { return ungroup(rows[index].id) }
        let next = index + 1
        if rows.indices.contains(next), !rows[next].isEmpty, rows[next].name.isEmpty {
            placeTab(id, inGroup: rows[next].id, at: 0)
        } else {
            moveTabToNewGroup(id)
        }
    }

    func ungroup(_ id: UUID) {
        guard let index = layout.workspaces.firstIndex(where: { $0.id == id }) else { return }
        layout.setCollapsed(false, workspace: id)
        layout.rename(workspaceAt: index, to: "")
    }

    /// A new tab at the end of a group, and the group opened to show it.
    func newTab(inGroup id: UUID) {
        guard let index = layout.workspaces.firstIndex(where: { $0.id == id }) else { return }
        layout.setCollapsed(false, workspace: id)
        if let last = layout.workspaces[index].columns.last { layout.focus(tabID: last.focusedTabID) }
        newTab(url: nil, in: selectedProfileID, workspace: index, activate: true)
    }

    /// Every tab in a group, and the group with them. The name goes first: a named row that runs out
    /// of windows asks whether to keep its name (`TilingWorkspaceRemoval`), and closing the group *is*
    /// the answer to that question.
    func closeGroup(_ id: UUID) {
        guard let index = layout.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let ids = layout.workspaces[index].columns.flatMap(\.tabIDs)
        layout.rename(workspaceAt: index, to: "")
        for tabID in ids { closeTab(tabID) }
        selectTabIfNone()
    }

    /// A tab dropped on a place in the row: `index` is a window position in the group it landed in.
    func placeTab(_ id: UUID, inGroup group: UUID, at index: Int) {
        guard let tab = tab(id), tab.profileID == selectedProfileID else { return }
        layout.placeTab(id, in: tab.profileID, workspace: group, at: index)
        syncSelection()
    }

    /// "Add Tab to New Group" — the tab into a row of its own, just after the one it was in.
    @discardableResult
    func moveTabToNewGroup(_ id: UUID) -> UUID? {
        guard let tab = tab(id) else { return nil }
        let created = layout.placeTabInNewWorkspace(id, in: tab.profileID)
        syncSelection()
        return created
    }

    /// Every other tab in the tab's own group.
    func closeOtherTabs(besides id: UUID) {
        guard let workspace = layout.workspaces.first(where: { $0.columns.contains { $0.holds(id) } }) else { return }
        selectTab(id)
        for other in workspace.columns.flatMap(\.tabIDs) where other != id { closeTab(other) }
    }

    /// A click on a tab, and the modifiers it came with — Chrome's rules on a Mac. Plain: that tab,
    /// alone. ⌘: that tab added to the pick, or taken out of it. ⇧: every tab along the bar from the
    /// last one clicked without ⇧ to this one. The clicked tab comes to the front in all three,
    /// except a ⌘-click that takes the tab in front out, which hands the front to another picked one.
    func clickTab(_ id: UUID, adding: Bool = false, extending: Bool = false) {
        let order = tabOrder(skippingCollapsed: true)
        if extending, let anchor = pickAnchor ?? selectedTabID,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            pickedTabs = Set(order[min(from, to)...max(from, to)])
            selectTab(id)
            return
        }
        if adding {
            var picks = pickedTabs.union(selectedTabID.map { [$0] } ?? [])
            pickAnchor = id
            if picks.contains(id), picks.count > 1 {
                picks.remove(id)
                pickedTabs = picks
                if selectedTabID == id, let next = order.first(where: picks.contains) { selectTab(next) }
                return
            }
            picks.insert(id)
            pickedTabs = picks
            selectTab(id)
            return
        }
        pickedTabs = [id]
        pickAnchor = id
        selectTab(id)
    }

    /// The picked tabs in the order the bar draws them.
    var pickedTabsInOrder: [UUID] { tabOrder().filter(pickedTabs.contains) }

    /// "Add Tabs to New Group": the tabs, in their order, into one new group just after the first
    /// one's. The tab in front stays in front.
    @discardableResult
    func moveTabsToNewGroup(_ ids: [UUID]) -> UUID? {
        guard let first = ids.first, let front = selectedTabID else { return nil }
        guard let created = moveTabToNewGroup(first) else { return nil }
        for (offset, id) in ids.dropFirst().enumerated() {
            placeTab(id, inGroup: created, at: offset + 1)
        }
        selectTab(front)
        return created
    }

    /// The tabs, in their order, to the end of a group.
    func moveTabs(_ ids: [UUID], toGroup group: UUID) {
        guard let front = selectedTabID else { return }
        for id in ids {
            let count = layout.workspaces.first { $0.id == group }?.columns.count ?? 0
            placeTab(id, inGroup: group, at: count)
        }
        selectTab(front)
    }

    /// "Show Side by Side": two picked tabs as the two halves of one column — a split, the same
    /// one ⌥S makes on the row. The second joins the first wherever it was, another group included.
    func showSideBySide(_ first: UUID, _ second: UUID) {
        let front = selectedTabID
        split(first, with: second)
        selectTab(front.flatMap { [first, second].contains($0) ? $0 : nil } ?? first)
    }

    /// "Stop Showing Side by Side": the split this tab is half of comes apart, the other half as a
    /// tab of its own just after it.
    func separate(_ id: UUID) {
        guard layout.columnMates(of: id).count > 1 else { return }
        selectTab(id)
        plainLayoutChange { _ = layout.toggleSplit() }
    }

    func closeTabs(_ ids: [UUID]) {
        for id in ids { closeTab(id) }
    }

    /// The tab bar always has one in front while there are any. The row can stand on its spare
    /// empty row with nothing focused; a tab bar has no such place, and would show nothing.
    func selectTabIfNone() {
        guard showsTabs, selectedTab == nil else { return }
        // The nearest group with a tab in it, looking back first: a group closed at the end of the
        // row leaves the one before it in front, the way closing the last tab does.
        let rows = layout.workspaces
        let here = layout.focusedWorkspaceIndex
        let nearest = (0...here).reversed().compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            + rows.dropFirst(here + 1)
        guard let row = nearest.first(where: { !$0.isEmpty }), let column = row.focusedColumn ?? row.columns.last,
              tab(column.focusedTabID) != nil else { return }
        selectTab(column.focusedTabID)
    }

    /// The focused column is the selected tab — everything else (assistant, agent panel, ⌘L) keys off it.
    private func syncSelection() {
        selectedTabID = layout.focusedTabID
        if showsTabs, selectedTab == nil { selectTabIfNone() }
        if let id = selectedTabID, !pickedTabs.contains(id) {
            pickedTabs = [id]
            pickAnchor = id
        }
        // Every way the focus can move ends here, which is why the ⌃Tab order is taken here and not
        // in `selectTab`: a row walked with ⌥→ is a row whose windows have been looked at.
        switcher.note(selectedTabID)
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
