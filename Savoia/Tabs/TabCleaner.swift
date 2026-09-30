import Foundation
import Observation

/// Once a period, offers to close the tabs left behind; `TabCleanup` decides which.
@MainActor
@Observable
final class TabCleaner {
    struct Proposal: Identifiable {
        let id = UUID()
        var tabs: [UUID]
        var days: Int
    }

    /// What is on screen, waiting for an answer.
    var proposal: Proposal?
    private(set) var isLooking = false

    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var vectors: [String: [Float]] = [:]

    private static let historyLimit = 200

    static let periods = [1, 3, 7, 14, 30]

    static func title(days: Int) -> String {
        switch days {
        case 1: String(localized: "Daily")
        case 3: String(localized: "Every 3 Days")
        case 7: String(localized: "Weekly")
        case 14: String(localized: "Every 2 Weeks")
        case 30: String(localized: "Monthly")
        default: String(localized: "Every \(days) Days")
        }
    }

    static func unopened(days: Int) -> String {
        switch days {
        case 1: String(localized: "Not opened for a day, and nothing read since is about them.")
        case 7: String(localized: "Not opened for a week, and nothing read since is about them.")
        case 14: String(localized: "Not opened for two weeks, and nothing read since is about them.")
        case 30: String(localized: "Not opened for a month, and nothing read since is about them.")
        default: String(localized: "Not opened for \(days) days, and nothing read since is about them.")
        }
    }

    func start(_ browser: BrowserState, settings: ConfigurationStore) {
        schedule?.cancel()
        schedule = Task { [weak self, weak browser, weak settings] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self, let browser, let settings else { return }
                let days = settings.tabCleanupDays
                if days > 0, proposal == nil,
                   Date.now >= (settings.tabCleanupLastPass ?? .now).addingTimeInterval(Double(days) * 86_400) {
                    await look(browser, days: days, settings: settings)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// A pass that could not judge leaves the date alone and is tried again within the hour.
    @discardableResult
    func look(_ browser: BrowserState, days: Int, settings: ConfigurationStore) async -> Int {
        guard !isLooking, days > 0 else { return 0 }
        isLooking = true
        defer { isLooking = false }
        let profileID = browser.selectedProfileID
        guard !browser.isPrivate(profileID), let embedder = browser.bookmarks?.embedder else { return 0 }
        let now = Date.now
        let since = now.addingTimeInterval(-Double(days) * 86_400)

        // Both halves of a split in front are being looked at.
        let front = browser.selectedTabID.map { browser.layout.columnMates(of: $0) } ?? []
        var candidates: [(tab: BrowserTab, group: UUID?)] = []
        for row in browser.layout.strip(for: profileID).workspaces {
            for column in row.columns where !column.isPinned {
                for id in column.tabIDs {
                    guard let tab = browser.tab(id), tab.isWebPage, !tab.showsStartPage else { continue }
                    if front.contains(id) { tab.seenAt = now }
                    candidates.append((tab, row.isGroup ? row.id : nil))
                }
            }
        }
        let visits = browser.history.recent(in: profileID, limit: Self.historyLimit).filter { $0.visitedAt >= since }
        let tabTexts = candidates.map { text($0.tab.title, $0.tab.currentURL) }
        let visitTexts = visits.map { text($0.title, $0.url) }
        let wanted = Set(tabTexts + visitTexts)
        vectors = vectors.filter { wanted.contains($0.key) }
        do {
            let missing = wanted.filter { vectors[$0] == nil }.sorted()
            if !missing.isEmpty {
                for (text, embedding) in zip(missing, try await embedder.embed(missing, as: TabSorter.role)) {
                    vectors[text] = embedding.vector
                }
            }
        } catch {
            Log.error(.browser, "tab cleanup: \(error.localizedDescription)")
            return 0
        }
        LocalLanguageModel.trimMemory()

        let tabs = zip(candidates, tabTexts).compactMap { candidate, text in
            vectors[text].map { TabCleanup.Tab(id: candidate.tab.id, vector: $0, host: host(candidate.tab.currentURL),
                                               seenAt: candidate.tab.seenAt, group: candidate.group) }
        }
        let history = zip(visits, visitTexts).compactMap { visit, text in
            vectors[text].map { TabCleanup.Interest(vector: $0, host: host(visit.url)) }
        }
        let read = history.count + tabs.filter { $0.seenAt >= since }.count
        guard read >= TabCleanup.Thresholds.standard.activity else {
            Log.info(.browser, "tab cleanup: \(read) pages read in \(days) days, too few to judge")
            return 0
        }
        settings.tabCleanupLastPass = now
        let offered = TabCleanup.abandoned(tabs, history: history, since: since)
        Log.info(.browser, "tab cleanup: \(offered.count) of \(tabs.count) left behind, against \(history.count) pages read")
        guard !offered.isEmpty, browser.selectedProfileID == profileID else { return 0 }
        proposal = Proposal(tabs: offered, days: days)
        return offered.count
    }

    /// The proposal's tabs still open and not brought to the front since.
    func stillOffered(in browser: BrowserState) -> [BrowserTab] {
        guard let proposal else { return [] }
        let since = Date.now.addingTimeInterval(-Double(proposal.days) * 86_400)
        return proposal.tabs.compactMap(browser.tab).filter { $0.seenAt < since }
    }

    private func text(_ title: String, _ url: URL?) -> String {
        let host = host(url)
        let clean = TabTopics.cleanTitle(title, host: host)
        return clean.isEmpty ? host : clean
    }

    private func host(_ url: URL?) -> String {
        guard let host = url?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension ConfigurationStore {
    /// Off by default, like grouping: a pass loads the embedding model.
    var tabCleanupDays: Int {
        get { self[.tabCleanupDays].flatMap(Int.init) ?? 0 }
        set {
            self[.tabCleanupDays] = String(newValue)
            // The first offer comes a whole period after it is switched on, not at once.
            if newValue > 0 { tabCleanupLastPass = .now }
        }
    }

    var tabCleanupLastPass: Date? {
        get { self[.tabCleanupLastPass].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
        set { self[.tabCleanupLastPass] = newValue.map { String($0.timeIntervalSince1970) } }
    }
}
