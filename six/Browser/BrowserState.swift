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

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private let profilesKey = "six.profiles"


    init() {
        var loaded = Profile.defaults
        if let data = UserDefaults.standard.data(forKey: "six.profiles"),
           let stored = try? JSONDecoder().decode([Profile].self, from: data), !stored.isEmpty {
            loaded = stored
        }
        profiles = loaded
        selectedProfileID = loaded[0].id
        layout.activeProfileID = loaded[0].id
        newTab()
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
        persistProfiles()
        selectProfile(profile.id)
    }

    func removeProfile(_ id: Profile.ID) {
        guard profiles.count > 1, let profile = profiles.first(where: { $0.id == id }) else { return }
        for tab in tabs(in: id) { closeTab(tab.id) }
        profiles.removeAll { $0.id == id }
        dataStores[profile.dataStoreID] = nil
        layout.removeProfile(id)
        persistProfiles()
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID) }
        if selectedProfileID == id { selectProfile(profiles[0].id) }
    }

    /// The profile's agent folder, created on first use. Nil (default) puts it back under Application Support.
    func setWorkingDirectory(_ url: URL?, for id: Profile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].workingDirectoryPath = url?.standardizedFileURL.path
        persistProfiles()
    }

    /// Ensures the profile's working directory exists and returns it.
    func workingDirectory(for profile: Profile) -> URL {
        let url = profile.workingDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
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
        let tab = BrowserTab(profileID: profile.id, dataStore: dataStore(for: profile))
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
        closed.page.stopLoading()
        let wasActive = closed.profileID == selectedProfileID
        withAnimation(NiriLayout.switchAnimation) {
            layout.removeColumn(tabID: id)
        }
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
    func cycleColumnWidth() { animateLayout { layout.cycleColumnWidth() } }
    func toggleFullWidth() { animateLayout { layout.toggleFullWidth() } }
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

    func toggleCenterFocus() { animateLayout { layout.setCentersFocus(!layout.centersFocus) } }

    func toggleOverview() {
        if layout.isOverview {
            exitOverview()
        } else {
            withAnimation(NiriLayout.switchAnimation) { layout.isOverview = true }
        }
    }

    func exitOverview() {
        guard layout.isOverview else { return }
        withAnimation(NiriLayout.switchAnimation) {
            layout.isOverview = false
            layout.scrollFocusIntoView() // free overview scrolling leaves the offset anywhere
        }
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
