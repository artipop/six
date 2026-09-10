import Foundation
import SixWebKitCore

@testable internal import SixCore

/// What the views read and call into.
///
/// In a target of its own, and that is not tidiness. Adwaita depends unconditionally on its own
/// SQLite (`meta-sqlite` → `CSQLite`) and `SixCore` reaches GRDB's, and Clang refuses to have both
/// in one compilation unit — *"'sqlite3_api_routines' has different definitions in different
/// modules"*. So nothing imports Adwaita and `SixCore` together: the model sits here, the views sit
/// in `SixUI`, and the seam the plan asked for is enforced by the compiler rather than by discipline.
public final class BrowserModel {
    /// A column, flattened for the view: what the strip needs to draw one, and nothing else.
    public struct Column: Identifiable {
        public let id: UUID
        public var frame: CGRect
        public var url: URL?
        public var title: String
        public var isFocused: Bool
        /// Whether this column is holding a real page. A discarded one keeps its place, its title
        /// and its address, and builds again when it is next shown.
        public var isLive: Bool
        /// A picture of the page as it was when it gave up its process, if there is one.
        public var thumbnail: URL?
        /// A question this page is waiting on, drawn as a bar under its title. On the column rather
        /// than on the window: in a strip of twenty, the page that wants the camera is one of them,
        /// and stopping the other nineteen to answer for it is a browser mistaking a page for
        /// itself. The Mac's `PermissionBar` sits in the same place for the same reason.
        public var permission: PermissionQuestion?
    }

    /// A question, flattened for the view.
    public struct PermissionQuestion: Identifiable, Equatable {
        public let id: UUID
        /// The site, as people name one: `example.com`.
        public let host: String
        /// "camera and microphone" — what the bar says it wants.
        public let devices: String
        public let wantsCamera: Bool
    }

    /// One model for the app, reached statically rather than stored in a view.
    ///
    /// Not a style choice: Meta collects a view's `@State` by reflecting over its stored properties,
    /// and a class sitting in one crashes the runtime inside `swift_getTypeByMangledName` — the
    /// window comes up, draws once, and dies. So the views hold value types only, and the model is
    /// here.
    public static let shared = BrowserModel()

    let layout = NiriLayout()
    /// One session per profile. A profile *is* its cookie jar — that is what makes private browsing
    /// private, rather than the app remembering to skip writes.
    private var sessions: [UUID: NetworkSession] = [:]
    private var privateProfiles: Set<UUID> = []
    private let defaultSession: NetworkSession

    private var history: HistoryStore?
    private var profileID = UUID()
    private var titles: [UUID: String] = [:]
    private var urls: [UUID: URL] = [:]
    private var pages = LivePages()
    private var settings: SettingsStore?
    private var bookmarks: Bookmarks?
    /// What sites were allowed, and what they are asking right now. The same object the Mac has,
    /// out of `SixCore`: the memory, the queue and the suspended page are shared code, and only the
    /// shape a request arrives in is not.
    private var permissions: SitePermissions?
    /// Told when a question appears or is answered. A question arrives from a C signal and assigns
    /// no view state, so without this the bar would exist and never be drawn.
    public var onPermissionQuestion: (() -> Void)?

    private init() {
        Thumbnails.folder = AppSupport.folder("Thumbnails")
        let profiles = AppSupport.folder("Profiles/Default")
        try? FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defaultSession = NetworkSession(directory: profiles)

        // The same file, in the same format, the Mac build writes; only the folder differs, and only
        // inside `AppSupport.root`. A browser without history is still a browser, so a database that
        // will not open is reported and stepped over rather than fatal.
        do {
            let database = try AppDatabase.open()
            history = HistoryStore(database: database)
            bookmarks = Bookmarks(database: database)
            // The profile id comes out of the settings table rather than being made fresh each
            // launch. Regenerating it orphans every visit the last run recorded — history that is
            // in the database and unreachable is worse than history that is missing.
            let settings = SettingsStore(database: database)
            SettingsStore.shared = settings
            self.settings = settings
            profileID = settings.defaultProfileID
            layout.activeProfileID = profileID

            let permissions = SitePermissions(settings: settings)
            // A private profile's answers live as long as the profile and are written nowhere —
            // the same rule as its cookies, and for the same reason.
            permissions.isPrivate = { [weak self] id in self?.privateProfiles.contains(id) ?? false }
            permissions.onQuestionsChanged = { [weak self] in self?.onPermissionQuestion?() }
            self.permissions = permissions
            listenForPermissionRequests()
        } catch {
            FileHandle.standardError.write(Data("[six] database unavailable: \(error)\n".utf8))
            profileID = layout.activeProfileID
        }
        // Populated here rather than from the app's `init` or the view's `onAppear`. `init` runs
        // before `g_application_run`, and this creates a `NetworkSession`, which is a GObject —
        // building one before GTK is up is the kind of mistake that fires later, in someone else's
        // code. `shared` is lazy, so the first touch happens inside the first render, by which time
        // the toolkit is running.
        if !restore() { fill() }
    }

    // MARK: Permissions

    /// Turn WebKitGTK's request into the question `SitePermissions` already knows how to answer.
    ///
    /// Everything past this function is shared with the Mac — the remembered answer, the queue, the
    /// suspended promise. What differs is only this: Apple hands the closure a `WKSecurityOrigin`,
    /// WebKitGTK hands it nothing and the origin comes from the page's own address.
    private func listenForPermissionRequests() {
        PermissionRequests.handler = { [weak self] ask, answer in
            guard let self, let permissions else { return answer(false) }
            var asked: [SitePermission] = []
            if ask.wantsCamera { asked.append(.camera) }
            if ask.wantsMicrophone { asked.append(.microphone) }
            guard let origin = SitePermissions.origin(of: ask.pageURL) else { return answer(false) }
            trace("permission \(origin) \(asked.map(\.rawValue).joined(separator: "+"))")
            permissions.decide(asked, origin: origin, in: ask.tabID,
                               profileID: self.layout.activeProfileID, then: answer)
        }
    }

    /// The bar's two buttons. Remembers the answer and lets the page go.
    public func answerPermission(_ allowed: Bool, for tabID: UUID) {
        permissions?.answer(allowed, for: tabID)
        trace("permission answered \(allowed)")
    }

    /// What the column that asked should be drawing, if anything.
    private func question(for tabID: UUID) -> PermissionQuestion? {
        guard let question = permissions?.question(for: tabID) else { return nil }
        return PermissionQuestion(
            id: question.id,
            host: question.host,
            // `ListFormatter` is Apple Foundation's, and this list is never longer than two.
            devices: question.permissions.map(\.label).joined(separator: " and "),
            wantsCamera: question.permissions.contains(.camera)
        )
    }

    /// Every site with a remembered answer — the Mac's Site Permissions panel, flattened.
    public struct PermissionRow: Identifiable {
        public let id: String
        public let origin: String
        public let detail: String
    }

    public var permissionSites: [PermissionRow] {
        guard let permissions else { return [] }
        return permissions.sites.map { site in
            let decided = permissions.decisions(forOrigin: site.origin, profileID: site.profileID)
            let detail = SitePermission.allCases.compactMap { permission -> String? in
                guard let allowed = decided[permission] else { return nil }
                return "\(permission.label): \(allowed ? "allowed" : "blocked")"
            }
            return PermissionRow(id: site.id, origin: site.origin,
                                 detail: detail.joined(separator: ", "))
        }
    }

    /// Take it back: the site asks again the next time it needs a device.
    public func forgetPermissions(_ id: String) {
        guard let permissions, let site = permissions.sites.first(where: { $0.id == id }) else { return }
        permissions.forget(origin: site.origin, profileID: site.profileID)
    }

    // MARK: Leaving and coming back

    /// Put the strip back the way it was left. Returns whether there was anything to put back — if
    /// not, the caller opens what the environment asked for instead.
    private func restore() -> Bool {
        guard let settings, let state = StripState.load(from: settings), state.isWorthKeeping else {
            return false
        }
        var strips: [UUID: NiriStrip] = [:]
        for (key, strip) in state.strips { if let id = UUID(uuidString: key) { strips[id] = strip } }
        guard !strips.isEmpty else { return false }

        layout.restore(strips: strips)
        if let active = UUID(uuidString: state.activeProfile) { layout.activeProfileID = active }
        for (key, value) in state.urls { if let id = UUID(uuidString: key) { urls[id] = URL(string: value) } }
        for (key, value) in state.titles { if let id = UUID(uuidString: key) { titles[id] = value } }
        for id in urls.keys { pages.touch(id) }
        trace("restore \(urls.count) columns")
        return true
    }

    /// Write the strip down. Called after anything that changes its shape — a column opened, closed,
    /// focused, or sent somewhere — because a browser that only saves on quit loses everything to
    /// the one crash it was going to have.
    public func save() {
        // A private profile has no place in the snapshot: it is recorded nowhere, and a relaunch
        // must not bring it back.
        guard let settings, !isPrivate else { return }
        var state = StripState()
        for (id, strip) in layout.allStrips { state.strips[id.uuidString] = strip }
        for (id, url) in urls { state.urls[id.uuidString] = url.absoluteString }
        for (id, title) in titles where !title.isEmpty { state.titles[id.uuidString] = title }
        state.activeProfile = layout.activeProfileID.uuidString
        state.save(to: settings)
    }

    // MARK: What the strip draws

    public var columns: [Column] {
        guard let workspace = layout.focusedWorkspace else {
            trace("columns: no workspace")
            return []
        }
        trace("columns: \(workspace.columns.count)")
        let scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview
        // What the strip is showing is pinned; the rest lives or dies by the budget.
        let all = workspace.columns.flatMap(\.tabIDs)
        let pinned = layout.visibleTabIDs
        let dropped = pages.settle(pinned: pinned, all: all)
        trace("budget \(pages.budget): \(pages.live.count) live of \(all.count), \(pinned.count) pinned, \(dropped.count) discarded")
        for id in dropped {
            trace("discard \(id.uuidString.prefix(8))")
            PageRegistry.forget(id)
        }

        // One entry per *window*, which is what `placements` is for: a column holds one window or
        // two side by side (`NiriColumn`). Nothing on this front makes a split — there is no ⌥S here
        // yet — but a rail written by the Mac over the same `six.sqlite` can arrive with one, and a
        // half that is not drawn is a window nobody can reach.
        return layout.placements(workspace.columns).map { place in
            Column(
                id: place.tabID,
                frame: place.frame.offsetBy(dx: -scroll, dy: 0),
                url: urls[place.tabID],
                title: titles[place.tabID] ?? "",
                isFocused: place.tabID == layout.focusedTabID,
                isLive: pages.live.contains(place.tabID),
                thumbnail: Thumbnails.exists(for: place.tabID) ? Thumbnails.url(for: place.tabID) : nil,
                permission: question(for: place.tabID)
            )
        }
    }

    /// How many pages may be live at once, and how many are.
    public var liveBudget: Int { pages.budget }
    public var liveCount: Int { pages.live.count }

    var focusedID: UUID? { layout.focusedTabID }

    /// The column on screen, for the chrome that has to ask something about the page in it — the
    /// translate button is the first, and it asks `TranslationController` rather than the model.
    public var focusedTabID: UUID? { layout.focusedTabID }

    /// The session a column should be built against: its profile's.
    public var session: NetworkSession {
        sessions[layout.activeProfileID] ?? defaultSession
    }

    /// Whether the strip on screen belongs to a private profile. Recorded nowhere, and the chrome
    /// says so.
    public var isPrivate: Bool { privateProfiles.contains(layout.activeProfileID) }

    /// Private browsing is a profile, not a mode — the same arrangement the Mac has. Its session is
    /// ephemeral, so cookies, storage and caches live in memory and go when it does; and because the
    /// profile is what is private, nothing downstream has to remember to behave differently.
    public func openPrivateProfile() {
        let id = UUID()
        privateProfiles.insert(id)
        sessions[id] = NetworkSession()
        layout.activeProfileID = id
        trace("private profile \(id.uuidString.prefix(8))")
        open(Self.startPage)
    }

    /// Back to the ordinary profile, and the private one is forgotten entirely — its session, its
    /// pages and its place in the strip.
    public func closePrivateProfile() {
        let id = layout.activeProfileID
        guard privateProfiles.contains(id) else { return }
        for id in layout.workspaces.flatMap({ $0.columns.flatMap(\.tabIDs) }) {
            PageRegistry.forget(id)
            pages.forget(id)
            permissions?.forget(id)
            urls[id] = nil
            titles[id] = nil
        }
        privateProfiles.remove(id)
        permissions?.forgetProfile(id)
        sessions[id] = nil
        layout.activeProfileID = profileID
        trace("private profile closed")
    }

    /// Where the strip should be scrolled to: the offset `NiriLayout` computes for the focused
    /// column, which is what centres it when `centersFocus` is on. The same number the Mac uses.
    public var scrollOffset: Double {
        guard let workspace = layout.focusedWorkspace else { return 0 }
        return Double(layout.resolvedOffset(workspace))
    }

    /// Tell the layout how big the strip actually is, and say whether that moved anything — so the
    /// front can redraw once and then stop.
    ///
    /// The Mac reads this from a `GeometryReader`. GTK has no equivalent, so the front reports the
    /// widget's own allocation instead; until it does, `NiriLayout`'s default stands, which is why a
    /// first render is laid out for a window nobody has measured yet. It was a hard-coded size here
    /// for a while, which is worse in the way a plausible wrong number always is: the columns were
    /// laid out for a window that did not exist and nothing looked broken enough to ask.
    public func updateViewport(_ size: CGSize) -> Bool {
        guard size.width > 1, size.height > 1, size != layout.viewport else { return false }
        layout.updateViewport(size)
        trace("viewport \(Int(size.width))×\(Int(size.height))")
        return true
    }

    /// The layout's own gap, so the front never invents a spacing of its own.
    public var gap: Double { Double(layout.gap) }
    /// What a column should be, in points. There is one width in the strip — a screen's worth of
    /// page, less the gaps — and this is it.
    public var columnSize: CGSize {
        CGSize(width: layout.columnWidth, height: layout.columnHeight)
    }
    public var canGoBack: Bool { focusedID.map(PageRegistry.canGoBack) ?? false }
    public var canGoForward: Bool { focusedID.map(PageRegistry.canGoForward) ?? false }

    // MARK: Driving it

    private func fill() {
        trace("fill")
        let requested = (ProcessInfo.processInfo.environment["SIX_URL"] ?? "")
            .split(separator: " ")
            .compactMap { URL(string: String($0)) }
        for url in requested.isEmpty ? [Self.startPage] : requested { open(url) }
    }

    public func openColumn() { open(Self.startPage) }

    public func open(_ url: URL) {
        trace("open \(url)")
        let tabID = UUID()
        urls[tabID] = url
        layout.insertColumn(tabID: tabID)
    }

    /// Anything that is not an address is a search, which is the one decision an address bar makes.
    public func go(to typed: String) {
        trace("go \(typed)")
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.destination(for: trimmed) else { return }
        if let focused = focusedID { urls[focused] = url } else { open(url) }
    }

    // MARK: Focus and the strip

    /// Focus a column. Clicking one focuses it, which is also what makes the strip scroll to it —
    /// `resolvedOffset` follows the focus, so the two are the same gesture.
    public func focus(_ tabID: UUID) {
        guard layout.focusedTabID != tabID else { return }
        trace("focus \(tabID)")
        layout.focus(tabID: tabID)
        pages.touch(tabID)
        save()
    }

    /// One column along the strip, the way ⌥← and ⌥→ do it on the Mac.
    public func focusColumn(_ delta: Int) {
        guard layout.canFocusColumn(delta) else { return trace("focusColumn \(delta): nowhere to go") }
        layout.focusColumn(delta)
        trace("focusColumn \(delta) -> \(layout.focusedTabID?.uuidString.prefix(8) ?? "—")")
    }

    public func canFocusColumn(_ delta: Int) -> Bool { layout.canFocusColumn(delta) }

    /// Workspaces stack across the strip, the way niri means them: columns follow one another
    /// *along* it, workspaces are the other axis. `NiriLayout` owns both; this only asks.
    public func focusWorkspace(_ delta: Int) {
        guard layout.canFocusWorkspace(delta) else { return trace("focusWorkspace \(delta): nowhere to go") }
        layout.focusWorkspace(delta)
        trace("focusWorkspace -> \(layout.focusedWorkspaceIndex) of \(layout.workspaces.count)")
    }

    /// Send the focused column to the next workspace along, which is how a strip gets tidied.
    public func moveColumnToWorkspace(_ delta: Int) { layout.moveColumnToWorkspace(delta) }

    // MARK: Overview

    /// The whole strip at once, scaled down. Not a layout of its own — `NiriLayout` reports the
    /// tiled geometry throughout, because the overview is a way of *looking* at the strip rather
    /// than a different arrangement of it.
    public var isOverview: Bool { layout.isOverview }

    public func toggleOverview() {
        layout.isOverview.toggle()
        trace("overview \(layout.isOverview ? "on" : "off") scale \(layout.overviewScale)")
    }

    /// How far to zoom out: enough to show the focused strip, never more than half, never past the
    /// floor where a long strip starts scrolling instead of getting microscopic.
    public var overviewScale: Double { layout.isOverview ? Double(layout.overviewScale) : 1 }

    /// The strip's full width, so the scaled canvas can ask for the right size.
    public var contentWidth: Double {
        guard let workspace = layout.focusedWorkspace else { return 0 }
        return Double(layout.contentWidth(workspace))
    }

    public var workspaceCount: Int { layout.workspaces.count }
    public var focusedWorkspaceIndex: Int { layout.focusedWorkspaceIndex }

    /// Close the focused column. The page goes with it — the registry drops its pointer, and the
    /// widget is removed by the strip on the next render.
    public func closeColumn() {
        guard let focused = focusedID else { return }
        trace("close \(focused)")
        layout.removeColumn(tabID: focused)
        PageRegistry.forget(focused)
        pages.forget(focused)
        TranslationController.shared.forget(focused)
        // The page is suspended inside `decide`; a promise that never lands is a page that never
        // finds out. Denying is the answer a closed column gives.
        permissions?.forget(focused)
        Thumbnails.prune(keeping: Set(layout.workspaces.flatMap { $0.columns.flatMap(\.tabIDs) }))
        save()
        urls[focused] = nil
        titles[focused] = nil
    }

    public func goBack() { focusedID.map(PageRegistry.goBack) }
    public func goForward() { focusedID.map(PageRegistry.goForward) }
    public func reload() { focusedID.map(PageRegistry.reload) }

    /// The address bar shows where the focused page actually is, which after a redirect or a
    /// followed link is not the address it was asked for.
    public var focusedURL: URL? {
        guard let focused = focusedID else { return nil }
        return PageRegistry.url(of: focused) ?? urls[focused]
    }

    // MARK: What the pages report

    /// Returns whether anything changed, so the front can redraw for a new title and stay still for
    /// the dozen identical ones a loading page sends. Redrawing on every one of them is what sent
    /// the view tree into a 248-render runaway.
    @discardableResult
    public func setTitle(_ title: String, for tabID: UUID) -> Bool {
        guard titles[tabID] != title else { return false }
        titles[tabID] = title
        if let url = urls[tabID], !title.isEmpty, !isPrivate {
            history?.updateTitle(title, for: url, in: profileID)
        }
        return true
    }

    @discardableResult
    public func setURL(_ url: URL, for tabID: UUID) -> Bool {
        guard urls[tabID] != url else { return false }
        urls[tabID] = url
        save()
        return true
    }

    public func didFinishLoad(_ url: URL, title: String, for tabID: UUID) {
        urls[tabID] = url
        // Before the private-window guard, and deliberately: translating is about reading a page,
        // not about recording that it was read. A private window gets the offer like any other.
        TranslationController.shared.pageChanged(tabID)
        TranslationController.shared.consider(tabID)
        guard !isPrivate else { return }
        history?.record(url, title: title, in: profileID)
        // Photographed when it finishes rather than when it is discarded. Waiting for the eviction
        // sounds tidier and takes no pictures at all: a column past the budget never becomes live,
        // so there is never a page there to photograph. The Mac takes its own on the way out *and*
        // once for a window that has never been drawn, which is the same admission.
        Thumbnails.capture(tabID)
    }

    /// `SIX_UI_DEBUG=1`, the same switch `NiriLayout` already uses: what the model was asked to do
    /// and what it thought it was doing. A front that draws nothing is either not being told or not
    /// listening, and this says which.
    func trace(_ message: @autoclosure () -> String) {
        guard NiriLayout.tracesUI else { return }
        FileHandle.standardError.write(Data("[six] model: \(message())\n".utf8))
    }

    // MARK: History

    /// A visit, flattened for the view — the same shape the Mac's sheet draws.
    public struct HistoryRow: Identifiable {
        public let id: String
        public let url: URL
        public let title: String
    }

    /// Empty query means the recent ones; anything else is a search. Both are queries against the
    /// `visits` table through `HistoryStore`, scoped to this profile — the front does not filter a
    /// list it holds in memory, because history outlives what fits in one.
    public func history(matching query: String) -> [HistoryRow] {
        guard let history else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visits = trimmed.isEmpty
            ? history.recent(in: profileID, limit: 200)
            : history.search(trimmed, in: profileID)
        return visits.map { HistoryRow(id: $0.id.uuidString, url: $0.url, title: $0.title) }
    }

    // MARK: Bookmarks

    /// A saved page, flattened for the view.
    public struct BookmarkRow: Identifiable {
        public let id: UUID
        public let url: URL
        public let title: String
        public let site: String
    }

    public func bookmarks(matching query: String) -> [BookmarkRow] {
        guard let bookmarks, let rows = try? bookmarks.all(in: profileID, matching: query) else { return [] }
        return rows.map { BookmarkRow(id: $0.id, url: $0.url, title: $0.displayTitle, site: $0.displayDetail) }
    }

    /// Save the focused page, or unsave it if it is already there. Private profiles keep nothing —
    /// a bookmark is a record like any other.
    public func toggleBookmark() {
        guard !isPrivate, let bookmarks, let focused = focusedID, let url = urls[focused] else { return }
        do {
            if try bookmarks.contains(url, in: profileID) {
                let existing = try bookmarks.all(in: profileID).filter { $0.url == url }
                for row in existing { try bookmarks.remove(row.id) }
                trace("bookmark removed \(url)")
            } else {
                try bookmarks.add(url: url, title: titles[focused] ?? "", profileID: profileID)
                trace("bookmark added \(url)")
            }
        } catch {
            FileHandle.standardError.write(Data("[six] bookmark failed: \(error)\n".utf8))
        }
    }

    public func removeBookmark(_ id: UUID) {
        try? bookmarks?.remove(id)
    }

    /// Whether the focused page is saved, so the star can say so.
    public var isBookmarked: Bool {
        guard let bookmarks, let focused = focusedID, let url = urls[focused] else { return false }
        return (try? bookmarks.contains(url, in: profileID)) ?? false
    }

    // MARK: Addresses

    public static var startPage: URL { URL(string: "https://duckduckgo.com/")! }

    /// A word with a dot and no spaces is a host; everything else is a query. Deliberately crude —
    /// the Mac's knows about schemes, IDN and local names, and this is a skeleton.
    public static func destination(for typed: String) -> URL? {
        if let url = URL(string: typed), url.scheme != nil, url.host() != nil { return url }
        if !typed.contains(" "), typed.contains("."), let url = URL(string: "https://" + typed) { return url }
        return SearchEngine.current.searchURL(for: typed)
    }
}
