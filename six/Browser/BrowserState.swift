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
    /// Visits, per profile.
    let history: HistoryStore
    /// Saved pages, per profile; wired at launch. Removing a profile removes its bookmarks.
    @ObservationIgnored var bookmarks: BookmarkStore?
    /// The Markdown files behind document windows.
    @ObservationIgnored let documents = DocumentStore()
    /// Highlights per URL; wired at launch.
    @ObservationIgnored var highlights: HighlightStore?
    /// Deep-research runs (see `ResearchRun`).
    var research: [ResearchRun] = []
    @ObservationIgnored private let settings: SettingsStore

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// Starts from a snapshot when there is one; otherwise with the default profiles and one window.
    init(snapshot: BrowserSnapshot? = nil, history: HistoryStore, settings: SettingsStore) {
        self.history = history
        self.settings = settings
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
    }

    // MARK: Snapshot

    var snapshot: BrowserSnapshot {
        BrowserSnapshot(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            tabs: tabs.map { tab in
                var entry = TabSnapshot(id: tab.id, profileID: tab.profileID, url: tab.showsStartPage ? nil : tab.currentURL, title: tab.title)
                if let document = tab.document {
                    entry.document = DocumentSnapshot(id: document.id, title: document.title, modifiedAt: document.modifiedAt,
                                                      fileURL: document.fileURL, showsPreview: document.showsPreview)
                }
                return entry
            },
            strips: layout.allStrips
                .map { StripSnapshot(profileID: $0.key, strip: $0.value) }
                .sorted { $0.profileID.uuidString < $1.profileID.uuidString },
            research: research
        )
    }

    /// Document text is autosaved on its own; this is for the way out.
    func flushDocuments() {
        documents.flush(tabs.compactMap(\.document))
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
                tabs.append(makeDocumentTab(id: tab.id, profile: profile, document: document))
            } else {
                tabs.append(makeTab(id: tab.id, profile: profile, restoring: tab.url, title: tab.title))
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

    func dataStore(for profile: Profile) -> WKWebsiteDataStore {
        if let store = dataStores[profile.dataStoreID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profile.dataStoreID)
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
        bookmarks?.removeAll(in: id)
        profiles.removeAll { $0.id == id }
        dataStores[profile.dataStoreID] = nil
        layout.removeProfile(id)
        history.clear(profileID: id)
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID) }
        if selectedProfileID == id { selectProfile(profiles[0].id) }
    }

    /// Wipes the profile's site data — cookies, local storage, IndexedDB, caches, everything the
    /// `WKWebsiteDataStore` holds — then reloads the profile's open pages, so the screen shows the
    /// signed-out state rather than a stale render. Restored windows that haven't loaded yet need
    /// nothing: they load fresh when shown.
    func clearSiteData(for id: Profile.ID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        await dataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for tab in tabs(in: id) where !tab.showsStartPage && tab.pendingURL == nil {
            _ = tab.page.reload(fromOrigin: true)
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
        tabs.first { $0.id == id }
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
        tabs.append(tab)
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
            guard let self, let url = tab.page.url else { return }
            switch outcome {
            case .committed: history.record(url, title: tab.page.title, in: tab.profileID)
            case .finished:
                history.updateTitle(tab.page.title, for: url, in: tab.profileID)
                highlights?.apply(to: tab)
            }
        }
        return tab
    }

    // MARK: Documents

    /// Opens a document window — a column of text next to the pages. Same placement rules as `newTab`.
    @discardableResult
    func newDocument(text: String = "", in profileID: Profile.ID? = nil, workspace: Int? = nil, activate: Bool = true) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let document = TextDocument(text: text)
        let tab = makeDocumentTab(profile: profile, document: document)
        documents.save(document)
        tabs.append(tab)
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
        documents.watch(document)
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
        if selectedProfileID != tab.profileID {
            selectedProfileID = tab.profileID
            layout.activeProfileID = tab.profileID
        }
        withAnimation(NiriLayout.switchAnimation) {
            layout.focus(tabID: id)
        }
        syncSelection()
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        closed.close()
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
