import Foundation
import Observation
import WebKit

/// Ad and tracker blocking, as WebKit does it: rules compiled once into a `WKContentRuleList` and
/// handed to the page before it loads. No extension, no proxy, nothing running inside the page —
/// the network layer of the content process drops the request, which is why this costs nothing at
/// page time and cannot be seen by the site's own scripts.
///
/// **One `WKUserContentController` per window** (they live in `PageControllers`). The obvious
/// arrangement — one per profile, shared by every page — makes the per-site allowlist expensive:
/// WebKit evaluates each rule list on its own, so an "unblock this site" rule in a second list does
/// *not* undo a block from the first, and the only honest way to allow a site would be to compile the
/// exception into every list again (ten seconds of work for one click). A window has a controller of
/// its own instead: a window showing an allowed site simply has no rule lists attached, and turning
/// the shield off is instant.
///
/// **Off means off.** With `isEnabled` false nothing is attached, nothing is downloaded and nothing
/// is compiled — the point of the switch is that someone who brings their own blocker is not paying
/// for ours.
///
/// **The rules WebKit cannot express go to `AdvancedRules`**, which runs them inside the page:
/// scriptlets, extended CSS and CSS injection, about 12 000 rules of AdGuard Base alone. They obey
/// the same switch and the same allowlist as everything else here — a window that gets no rule
/// lists gets no user scripts either — and they are installed from the same navigation hook, which
/// is what makes them arrive before the page's own scripts rather than after them.
@MainActor
@Observable
final class ContentBlocker {
    /// What the panel shows for one list.
    struct Status: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case idle
            case updating
            case compiling
            case failed(String)
        }
        var phase: Phase = .idle
        var updatedAt: Date?
        var rules = 0
        var dropped = 0
        /// Rules that run in the page rather than in the network layer.
        var advanced = 0
        /// Compiled and attached — the list is actually blocking.
        var isReady = false
    }

    private let settings: SettingsStore
    @ObservationIgnored private let store = FilterListStore()
    @ObservationIgnored private let ruleStore = WKContentRuleListStore.default()
    @ObservationIgnored private let advanced = AdvancedRules()

    private(set) var lists: [FilterList]
    private(set) var status: [String: Status] = [:]
    /// Hosts the user chose to leave alone, as bare hostnames (`example.com` covers `www.example.com`).
    private(set) var allowlist: Set<String>
    /// Something is downloading, converting or compiling — the panel and the menu say so.
    private(set) var isWorking = false

    /// The master switch. Writing it puts the rules on or takes them off every window at once.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings.blockingEnabled = isEnabled
            applyToAllWindows()
            if isEnabled { Task { await prepare() } }
        }
    }

    /// Compiled lists, by list id.
    @ObservationIgnored private var compiled: [String: WKContentRuleList] = [:]
    /// The windows' controllers, and what each window is showing — the pair decides what is attached.
    @ObservationIgnored private let controllers: PageControllers
    /// The whole address, not just the host: a cosmetic rule can be written for one path, and the
    /// engine is asked about the page that is actually loading.
    @ObservationIgnored private var addresses: [UUID: URL] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Of the advanced rules the engine was last built from — rebuilding is the better part of a
    /// second, and six-hourly refreshes mostly change nothing.
    @ObservationIgnored private var advancedHash = ""
    private static let scriptName = "blocking"

    /// Filter lists go stale the way bookmarks do, and are refreshed on the same terms: once at
    /// launch, then every six hours for as long as the app is up.
    func startRefreshSchedule() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.prepare()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    init(settings: SettingsStore, controllers: PageControllers) {
        self.settings = settings
        self.controllers = controllers
        self.isEnabled = settings.blockingEnabled
        self.lists = FilterList.merge(stored: settings.blockingLists)
        self.allowlist = Set(settings.blockingAllowlist)
        controllers.onController { [weak self] windowID, _ in self?.apply(to: windowID) }
        AdvancedRules.checkPayloadVersions()
    }

    // MARK: What a window gets

    /// The window closed for good.
    func forget(_ windowID: UUID) {
        addresses[windowID] = nil
    }

    /// The window is about to show — or has just committed to — an address. Called before the load
    /// starts, so a site on the allowlist never has the rules applied to it in the first place.
    func note(_ windowID: UUID, showing url: URL?) {
        guard addresses[windowID] != url else { return }
        addresses[windowID] = url
        apply(to: windowID)
    }

    // MARK: The allowlist

    /// Is blocking off for this address — because the switch is off, or because the site is allowed?
    func allows(_ url: URL?) -> Bool {
        guard isEnabled else { return true }
        guard let host = url?.host()?.lowercased() else { return false }
        return isAllowed(host)
    }

    func isAllowed(_ host: String) -> Bool {
        if allowlist.contains(host) { return true }
        // `example.com` on the list covers `www.example.com` and `cdn.example.com`.
        return allowlist.contains { host.hasSuffix(".\($0)") }
    }

    /// Allow (or block again) every site under this one's host.
    func setAllowed(_ allowed: Bool, for url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if allowed {
            allowlist.insert(bare)
        } else {
            allowlist.remove(bare)
            allowlist = allowlist.filter { !host.hasSuffix(".\($0)") && $0 != host }
        }
        settings.blockingAllowlist = allowlist.sorted()
        applyToAllWindows()
    }

    func clearAllowlist() {
        allowlist = []
        settings.blockingAllowlist = []
        applyToAllWindows()
    }

    // MARK: The lists

    func setEnabled(_ enabled: Bool, forListID id: String) {
        guard let index = lists.firstIndex(where: { $0.id == id }), lists[index].isEnabled != enabled else { return }
        lists[index].isEnabled = enabled
        settings.blockingLists = lists
        if enabled {
            Task { await prepare() }
        } else {
            compiled[id] = nil
            status[id]?.isReady = false
            applyToAllWindows()
            Task { await rebuildAdvanced() }
        }
    }

    /// A list someone added by URL. The id is derived from the address, so adding the same list
    /// twice is one list.
    func addList(source: URL, title: String) {
        let id = "custom-" + FilterListStore.hash(of: source.absoluteString)
        guard !lists.contains(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespaces)
        lists.append(FilterList(
            id: id,
            title: name.isEmpty ? (source.host() ?? "Custom list") : name,
            detail: source.absoluteString,
            source: source
        ))
        settings.blockingLists = lists
        Task { await prepare() }
    }

    func removeList(_ id: String) {
        guard let list = lists.first(where: { $0.id == id }), !list.isBuiltIn else { return }
        lists.removeAll { $0.id == id }
        compiled[id] = nil
        status[id] = nil
        settings.blockingLists = lists
        applyToAllWindows()
        Task {
            await store.remove(id)
            await rebuildAdvanced()
        }
    }

    // MARK: Fetching, converting, compiling

    /// The launch path, and the path after any change to what is enabled. Everything already on
    /// disk and already compiled is a lookup (a fraction of a millisecond); only a list that is
    /// missing or newer than what WebKit holds costs real time.
    func prepare(forcingUpdate force: Bool = false) async {
        guard isEnabled, ruleStore != nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        for list in lists where list.isEnabled {
            let days = force ? 0 : settings.blockingRefreshDays
            var changed = false
            status[list.id, default: Status()].phase = .updating
            do {
                changed = try await store.download(list, olderThan: days, force: force)
            } catch {
                // A list that failed to update is not a list that stopped working: the copy on disk
                // keeps blocking, and the panel says when it was last fetched.
                Self.log("\(list.id) update failed: \(error.localizedDescription)")
                status[list.id, default: Status()].phase = .failed(error.localizedDescription)
            }
            await compile(list, force: changed)
        }

        await rebuildAdvanced()
        await pruneStaleRuleLists()
        applyToAllWindows()
    }

    /// One engine over the advanced rules of every enabled list, concatenated.
    ///
    /// Concatenated on purpose, and this is the one place six's blocking is *better* than WebKit's
    /// own: rule lists are evaluated separately, so an exception in one cannot undo a rule from
    /// another. There is only one engine, so `@@||example.com^$elemhide` in a regional list does
    /// cancel a cosmetic rule from the base list — which is what its author meant.
    private func rebuildAdvanced() async {
        var texts: [String] = []
        for list in lists where list.isEnabled {
            if let text = await store.advancedRules(for: list) { texts.append(text) }
        }
        let combined = texts.joined(separator: "\n")
        let hash = FilterListStore.hash(of: combined)
        guard hash != advancedHash else { return }
        advancedHash = hash
        await advanced.rebuild(from: combined)
        applyToAllWindows()
    }

    /// Fetches every list now, whatever its age.
    func updateNow() async {
        await prepare(forcingUpdate: true)
    }

    private func compile(_ list: FilterList, force: Bool) async {
        guard let ruleStore else { return }
        let entry = await store.entry(for: list.id)
        if !force, let hash = entry?.sourceHash,
           let existing = try? await ruleStore.contentRuleList(forIdentifier: Self.identifier(list.id, hash)) {
            compiled[list.id] = existing
            status[list.id] = Status(phase: .idle, updatedAt: entry?.updatedAt, rules: entry?.safariRules ?? 0,
                                     dropped: entry?.droppedRules ?? 0, advanced: entry?.advancedRules ?? 0,
                                     isReady: true)
            return
        }

        status[list.id, default: Status()].phase = .compiling
        guard let converted = await store.safariJSON(for: list) else {
            status[list.id, default: Status()].phase = .failed("no rules on disk")
            return
        }
        let started = ContinuousClock.now
        do {
            let identifier = Self.identifier(list.id, converted.hash)
            let ruleList = try await ruleStore.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: converted.json)
            let entry = await store.entry(for: list.id)
            compiled[list.id] = ruleList
            status[list.id] = Status(phase: .idle, updatedAt: entry?.updatedAt, rules: entry?.safariRules ?? 0,
                                     dropped: entry?.droppedRules ?? 0, advanced: entry?.advancedRules ?? 0,
                                     isReady: ruleList != nil)
            Self.log("compiled \(list.id) (\(entry?.safariRules ?? 0) rules) in \(started.duration(to: .now))")
        } catch {
            Self.log("\(list.id) compile failed: \(error.localizedDescription)")
            status[list.id, default: Status()].phase = .failed(error.localizedDescription)
        }
    }

    /// WebKit keeps every rule list it ever compiled. Ours are named `six.<list>.<hash>`, so the
    /// ones from an older version of a list can be found and dropped — otherwise a year of daily
    /// updates is a year of dead rule lists on disk.
    private func pruneStaleRuleLists() async {
        guard let ruleStore else { return }
        var keep: Set<String> = []
        for list in lists where list.isEnabled {
            if let hash = await store.entry(for: list.id)?.sourceHash {
                keep.insert(Self.identifier(list.id, hash))
            }
        }
        let identifiers = await ruleStore.availableIdentifiers() ?? []
        for identifier in identifiers where identifier.hasPrefix(Self.prefix) && !keep.contains(identifier) {
            try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
            Self.log("dropped stale rule list \(identifier)")
        }
    }

    // MARK: Attaching

    private var activeLists: [WKContentRuleList] {
        guard isEnabled else { return [] }
        return lists.filter(\.isEnabled).compactMap { compiled[$0.id] }
    }

    private func apply(to windowID: UUID) {
        let url = addresses[windowID]
        let allowed = !isEnabled || (url?.host()?.lowercased()).map(isAllowed) == true
        // Before the controller check: a window that has not built one yet still records what it
        // should run, and `PageControllers` hands it over when it does.
        controllers.setUserScripts(allowed ? [] : advancedScripts(for: url),
                                   named: Self.scriptName, for: windowID)
        guard let controller = controllers.existing(windowID) else { return }
        controller.removeAllContentRuleLists()
        guard !allowed else { return }
        for list in activeLists { controller.add(list) }
    }

    /// A page's cosmetic rules and scriptlets, as the user scripts that carry them.
    private func advancedScripts(for url: URL?) -> [WKUserScript] {
        guard let url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return [] }
        let rules = advanced.rules(for: url)
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil {
            Self.log("\(url.host() ?? "?"): \(rules.css.count) css, \(rules.extendedCSS.count) extended, \(rules.scripts.count) scripts")
        }
        guard !rules.isEmpty else { return [] }
        return advanced.userScripts(for: rules)
    }

    private func applyToAllWindows() {
        controllers.forEach { windowID, _ in apply(to: windowID) }
    }

    // MARK: Housekeeping

    private static let prefix = "six."

    private static func identifier(_ listID: String, _ hash: String) -> String {
        "\(prefix)\(listID).\(hash)"
    }

    nonisolated static func log(_ message: @autoclosure () -> String) {
        Log.info(.blocking, message())
    }
}
