import Foundation
import Observation
import WebKit

/// How many pages the app keeps live, and which ones.
///
/// A `WebPage` is not a data structure: it is a web content process with a JavaScript heap, a render
/// tree, timers and a compositor of its own — tens to a couple of hundred megabytes each. A strip of
/// a hundred windows cannot hold a hundred of them, and the ones that are not on screen are paying
/// for nothing.
///
/// Every browser solves this the same way and calls it *discarding* (Chrome's Memory Saver, Safari's
/// suspended tabs): keep the pages you are likely to come straight back to, give the rest of them
/// back to the system, and build them again from the address when they are asked for. Discarding is
/// not closing — the window stays in the strip with its title, its address, its back/forward stacks,
/// its scroll offset and a picture of what it last looked like (see `BrowserTab.discard`).
///
/// The policy:
///
/// * **What is on screen is never discarded.** The layout pins it (`BrowserState.refreshLivePages`).
/// * **Everything else is one LRU queue for the whole app** — every profile, every workspace. That
///   is what makes stepping over to another workspace and back cheap: the windows you just left are
///   at the warm end of the queue and their pages are still there when you come back. Only the cold
///   tail is spent.
/// * **Guards before eviction**, the ones Chrome uses: a page that is still loading, playing audio
///   or video, or holding something the user typed into a form is skipped and the next candidate
///   taken. One of six's own is on that list: a page whose video is in the floating
///   picture-in-picture window, which is being watched while its window is nowhere near the screen.
/// * **Memory pressure shrinks the budget** — `.warning` halves it, `.critical` keeps only what is
///   on screen — and it grows back when the pressure lifts.
///
/// There is no library here on purpose. A generic LRU (`NSCache` is not one — its eviction order is
/// undefined; `nicklockwood/LRUCache` is) holds interchangeable values, and pages are not
/// interchangeable: some are pinned, some are protected, and eviction is asynchronous because the
/// guards have to ask the page a question first. That is the whole cache, not the queue around it.
@MainActor
@Observable
final class LivePageCache {
    /// Pages the app is holding, least recently used first.
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var registry: [UUID: WeakTab] = [:]
    /// Windows the layout is showing right now: pinned, and never eviction candidates.
    @ObservationIgnored private var visible: Set<UUID> = []
    /// The window that gets a page built for it — the focused one, and nothing in the overview.
    @ObservationIgnored private var built: UUID?

    /// How many live pages the app aims to keep. Sized from the machine: about one page per gigabyte
    /// of RAM, never fewer than eight (a workspace and its neighbours, with room to step out and back)
    /// and never more than thirty-two, past which the win is imaginary and the risk of running the
    /// machine out of memory is not.
    var budget: Int {
        didSet { if budget != oldValue { scheduleTrim() } }
    }

    /// Live pages right now, for the menu's status line.
    private(set) var liveCount = 0

    /// The band the system last reported, and when it said so.
    @ObservationIgnored private var reported: (level: Pressure, at: Date) = (.normal, .distantPast)

    /// Memory pressure as it stands — and it expires.
    ///
    /// The system reports a *transition*: one notification when it enters a band and one when it
    /// leaves. Nothing guarantees the second ever arrives — a mask that misses it, a source that was
    /// asleep, a machine that simply never comes all the way back — and a browser that shrank its
    /// budget on a warning it heard once would stay pessimistic for the rest of the launch, which is
    /// exactly the bug you cannot see. So a warning is worth ninety seconds and then it is over. If
    /// the pressure is real, growing back is what makes the system say so again.
    @ObservationIgnored private var pressure: Pressure {
        guard reported.level != .normal else { return .normal }
        return Date().timeIntervalSince(reported.at) < Self.pressureMemory ? reported.level : .normal
    }

    private static let pressureMemory: TimeInterval = 90
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var trimTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    private enum Pressure { case normal, warning, critical }

    private final class WeakTab {
        weak var tab: BrowserTab?
        init(_ tab: BrowserTab) { self.tab = tab }
    }

    static var defaultBudget: Int {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return min(32, max(8, Int(gigabytes)))
    }

    /// `SIX_LIVE_PAGES=n` overrides the budget, `SIX_PAGE_CACHE_DEBUG=1` narrates evictions on stderr.
    ///
    /// Nothing else moves it. It used to be a picker in the Layout menu, which asked a person to
    /// answer a question they have no way to answer — how many web content processes this Mac can
    /// carry is what `defaultBudget` reads off the machine, and what memory pressure adjusts while
    /// the app runs. The environment variable stays because measuring wants a fixed number.
    init(budget: Int? = nil) {
        let override = ProcessInfo.processInfo.environment["SIX_LIVE_PAGES"].flatMap(Int.init)
        self.budget = override ?? budget ?? Self.defaultBudget
        watchMemoryPressure()
    }

    // MARK: Bookkeeping

    /// A window has just built a page. Called by `BrowserTab` itself, so nothing can hold a live page
    /// the cache does not know about.
    func noteLive(_ tab: BrowserTab) {
        registry[tab.id] = WeakTab(tab)
        touch(tab.id)
        scheduleTrim()
    }

    /// This window was used: it goes to the warm end of the queue.
    func touch(_ id: UUID) {
        if let index = order.firstIndex(of: id) { order.remove(at: index) }
        order.append(id)
    }

    /// The window is gone (closed, or its profile removed): every queue it stood in forgets it.
    func forget(_ id: UUID) {
        order.removeAll { $0 == id }
        pictured.removeAll { $0 == id }
        registry[id] = nil
        visible.remove(id)
        if built == id { built = nil }
        liveCount = liveTabs().count
    }

    /// The windows the layout is showing, and the one window that may be *built*.
    ///
    /// Pinning and building are deliberately two different things. Everything on screen is pinned —
    /// nothing it still has is taken away, so the neighbours peeking in at the edges keep showing
    /// their pages. Only the focused window is built: walking down a restored strip, or flying around
    /// the overview, must not load a page per window on the way past. You get the page when you land
    /// on it, and if you were there recently it is still warm and there is nothing to load.
    func setVisible(_ ids: Set<UUID>, building: UUID?, resolve: (UUID) -> BrowserTab?) {
        guard ids != visible || building != built else { return }
        let left = visible.subtracting(ids)
        visible = ids
        built = building
        for id in ids { touch(id) }
        build(building.flatMap { resolve($0) })
        // A window on its way off screen is still mounted this turn: the last chance to ask it where
        // it is scrolled to and what it looks like.
        for id in left { resolve(id)?.rememberViewState() }
        scheduleTrim()
    }

    /// Builds the focused window's page — once the focus has stopped moving.
    ///
    /// Building is not free and it is not asynchronous: `WebPage()` is a web content process being
    /// attached, measured here at 6–250 ms on the main actor, and the load that follows it is more.
    /// Doing that inside the click that moved the focus is a third of a second of stuck button, and
    /// stepping along the strip with the edge buttons or ⌥→ would pay it at every window on the way
    /// past. So the focus is allowed to settle first: hold ⌥→ across ten windows and exactly one page
    /// is built, the one you stopped at. A window that already has its page is shown at once — there
    /// is nothing to wait for.
    private func build(_ tab: BrowserTab?) {
        buildTask?.cancel()
        buildTask = nil
        // Nothing to build: the window is on the start page, or its page is already there and loaded.
        guard let tab, tab.needsBuilding else { return }
        let id = tab.id
        buildTask = Task { [weak self, weak tab] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, let tab, visible.contains(id) else { return }
            tab.prepareForDisplay()
            scheduleTrim()
        }
    }

    /// How long the focus has to sit still before the window under it is worth building. One switch
    /// animation (`NiriLayout.switchAnimation` is 0.34 s), so the work lands after the strip settles.
    private static let settleDelay = Duration.milliseconds(350)

    /// Windows holding a picture of themselves, oldest first.
    @ObservationIgnored private var pictured: [UUID] = []

    /// A window has just drawn itself. The pictures are what the overview is made of, so they outlive
    /// the pages by a good margin — but a decoded bitmap per window is real memory too, and the point
    /// of all this was to give memory back. Four windows' worth of pictures per live page, and the
    /// oldest lets go of its.
    func notePicture(_ tab: BrowserTab) {
        if let index = pictured.firstIndex(of: tab.id) { pictured.remove(at: index) }
        pictured.append(tab.id)
        if registry[tab.id]?.tab == nil { registry[tab.id] = WeakTab(tab) }
        let limit = max(24, budget * 4)
        while pictured.count > limit {
            let id = pictured.removeFirst()
            registry[id]?.tab?.forgetPicture()
        }
    }

    // MARK: Eviction

    /// The budget as memory pressure leaves it.
    ///
    /// `.warning` is not an emergency and on a small machine it is not even unusual — an 8 GB Mac with
    /// a browser and an editor open sits in it most of the day. Halving the budget there made the
    /// browser permanently pessimistic about a state that is normal, so it gives up a third instead,
    /// and never goes below the size of a workspace. `.critical` is the emergency: only what is on
    /// screen survives it.
    private var effectiveBudget: Int {
        switch pressure {
        case .normal: budget
        case .warning: max(6, budget * 2 / 3)
        case .critical: 0
        }
    }

    private func liveTabs() -> [BrowserTab] {
        var dead: [UUID] = []
        var tabs: [BrowserTab] = []
        for id in order {
            guard let tab = registry[id]?.tab else { dead.append(id); continue }
            if tab.hasLivePage { tabs.append(tab) }
        }
        for id in dead { registry[id] = nil; order.removeAll { $0 == id } }
        return tabs
    }

    private func scheduleTrim() {
        guard trimTask == nil else { return }
        trimTask = Task { [weak self] in
            await self?.trim()
            self?.trimTask = nil
        }
    }

    /// Walks the queue from the cold end, discarding until the app is inside its budget. Skipped
    /// candidates (loading, playing, holding typed-in text) are passed over for this pass only.
    private func trim(target: Int? = nil) async {
        let limit = target ?? effectiveBudget
        var protected: Set<UUID> = []
        while true {
            let tabs = liveTabs()
            liveCount = tabs.count
            guard tabs.count > limit else { return }
            let candidate = tabs.first {
                !visible.contains($0.id) && !protected.contains($0.id)
            }
            guard let candidate else { return } // everything left is on screen or protected
            if let reason = await keepAliveReason(candidate) {
                protected.insert(candidate.id)
                Self.log("keeping \(candidate.title): \(reason)")
                continue
            }
            candidate.discard()
            order.removeAll { $0 == candidate.id }
            Self.log("discarded \(candidate.title) — \(liveTabs().count)/\(limit) live")
        }
    }

    /// Chrome's exclusions: a page doing something the user would notice losing is not a candidate.
    private func keepAliveReason(_ tab: BrowserTab) async -> String? {
        if tab.isLoadingRecently { return "still loading" }
        if await tab.isPlayingMedia { return "playing media" }
        // The floating player is the one thing on this list that is *on screen* while its window is
        // not: the whole point of picture-in-picture is to scroll away from the page and keep
        // watching, and discarding that page takes the video off the screen the person is looking
        // at. The line above covers it while it plays; this one is for the moment it is paused, which
        // is not a corner case — it is what pausing the floating player does, and without this line
        // the very next trim discarded the page out from under it, measured.
        if await tab.isInPictureInPicture { return "picture-in-picture" }
        if await tab.hasUserInput { return "unsent form input" }
        return nil
    }

    /// Everything not on screen, now — what the menu item asks for, and a way to see what discarding
    /// costs while testing.
    func discardBackgroundPages() {
        Task { @MainActor in
            await trimTask?.value
            await trim(target: 0)
        }
    }

    // MARK: Memory pressure

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let data = self.pressureSource?.data else { return }
                let level: Pressure = data.contains(.critical) ? .critical : (data.contains(.warning) ? .warning : .normal)
                self.reported = (level, Date())
                Self.log("memory pressure: \(level) — budget \(self.effectiveBudget)")
                self.scheduleTrim()
            }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: Debug

    static let debugging = ProcessInfo.processInfo.environment["SIX_PAGE_CACHE_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard debugging else { return }
        FileHandle.standardError.write(Data("[six] pages: \(message())\n".utf8))
    }
}

