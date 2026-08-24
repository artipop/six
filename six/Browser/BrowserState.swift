import Foundation
import Observation
import WebKit

/// App-wide browser model: profiles (each with an isolated data store) and tabs across all profiles, shown in one window.
@MainActor
@Observable
final class BrowserState {
    private(set) var profiles: [Profile]
    private(set) var tabs: [BrowserTab] = []
    var selectedProfileID: Profile.ID
    var selectedTabID: BrowserTab.ID?

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private let profilesKey = "six.profiles"

    nonisolated static let homeURL = URL(string: "https://duckduckgo.com")!

    init() {
        var loaded = Profile.defaults
        if let data = UserDefaults.standard.data(forKey: "six.profiles"),
           let stored = try? JSONDecoder().decode([Profile].self, from: data), !stored.isEmpty {
            loaded = stored
        }
        profiles = loaded
        selectedProfileID = loaded[0].id
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
        selectedProfileID = id
        if let tab = tabs(in: id).first {
            selectedTabID = tab.id
        } else {
            newTab()
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
        persistProfiles()
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreID) }
        if selectedProfileID == id { selectProfile(profiles[0].id) }
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

    func tabs(in profileID: Profile.ID) -> [BrowserTab] {
        tabs.filter { $0.profileID == profileID }
    }

    @discardableResult
    func newTab(url: URL = BrowserState.homeURL, in profileID: Profile.ID? = nil) -> BrowserTab {
        let profile = profiles.first { $0.id == profileID } ?? selectedProfile
        let tab = BrowserTab(profileID: profile.id, dataStore: dataStore(for: profile))
        tabs.append(tab)
        selectedProfileID = profile.id
        selectedTabID = tab.id
        tab.load(url)
        return tab
    }

    func selectTab(_ id: BrowserTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedProfileID = tab.profileID
        selectedTabID = id
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closed = tabs.remove(at: index)
        closed.page.stopLoading()
        if selectedTabID == id {
            let siblings = tabs(in: closed.profileID)
            selectedTabID = siblings.last?.id
            if selectedTabID == nil { newTab(in: closed.profileID) }
        }
    }

    func closeSelectedTab() {
        if let id = selectedTabID { closeTab(id) }
    }
}
