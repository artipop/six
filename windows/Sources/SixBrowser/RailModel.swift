import Foundation
import GRDB

@testable internal import SixCore

/// The rail's own state: `NiriLayout` plus what a column needs to draw itself and, once it is
/// live, to load.
///
/// The profiles are the same two tables the Mac reads, in the same file, and which one is on screen
/// outlives the process — and so, now, does the strip: `StripState`, the same row the Linux front
/// writes, under the same key. The rail and its mechanics — open, close, focus, move, the
/// workspaces stacked above and below it — are the same shape here as on every other front because
/// `NiriLayout` is the same code, unchanged, imported the way the Linux front already does:
/// `@testable` because its members are `internal` and were never meant to be a public API, only a
/// shared one — SwiftPM enables testability for debug builds across the whole graph, which is what
/// makes this legal.
public final class RailModel {
    /// A column, flattened for the view: its on-screen frame and what to write on it.
    public struct Column: Identifiable {
        public let id: UUID
        public var frame: CGRect
        public var title: String
        public var isFocused: Bool
        /// A question this page is waiting on, drawn as a bar under its title. On the column rather
        /// than on the window, for the reason the Mac's `PermissionBar` gives: one page in a strip of
        /// twenty wanting the camera is no reason to stop the other nineteen.
        public var permission: PermissionQuestion?
    }

    /// A question, flattened for the view.
    public struct PermissionQuestion: Equatable {
        /// The site, as people name one: `example.com`.
        public let host: String
        /// "camera and microphone" — what the bar says it wants.
        public let devices: String
        public let wantsCamera: Bool
    }

    /// A card as the overview draws it: every workspace's columns at once, already scaled and placed
    /// in the rail's own coordinates.
    public struct OverviewCard: Identifiable {
        public let id: UUID
        public var frame: CGRect
        public var title: String
        public var isFocused: Bool
    }

    /// A workspace's name in the overview, where its row begins.
    public struct OverviewRow: Identifiable {
        public var id: Int { index }
        public let index: Int
        public let title: String
        public let left: Double
        public let top: Double
        public let isFocused: Bool
    }

    /// The same address `linux/Sources/SixBrowser/BrowserModel` opens a fresh column on, and the
    /// same `SIX_URL` override — the only way to point a run at a test page without a keyboard.
    public static let startURL = ProcessInfo.processInfo.environment["SIX_URL"] ?? "https://duckduckgo.com/"

    public static let shared = RailModel()

    let layout = NiriLayout()
    private var titles: [UUID: String] = [:]
    private var urls: [UUID: String] = [:]
    /// Columns whose last visit was recorded before its page had a title (`awaitsTitle`).
    private var awaitingTitle: Set<UUID> = []
    private var nextTabNumber = 1
    /// Which columns keep a real `WKView` — the Mac's rule, shared with Linux (`LivePages`).
    private var pages = LivePages()

    /// The profiles, and which one is on screen. `NiriLayout` already keeps a strip per profile, so
    /// switching is nothing but assigning `activeProfileID` — this front gets the whole mechanic for
    /// the price of the list.
    private var profileRecords: [ProfileRecord] = []
    private var privateProfile: ProfileInfo?
    private var selectedProfileID = UUID()
    private let profileStore: ProfileStore
    /// Not private: `Bookmarks.swift` is the rest of this type in another file, because what it
    /// wires up — an embedder in an off-screen page — has nothing to do with a rail.
    let settings: SettingsStore
    /// The saved pages and their vectors. Made here, because the database is; given an embedder
    /// later by `attachSandbox`, because that needs a window.
    private(set) var bookmarks: BookmarkIndexer?
    /// The `visits` table, through the same store the Mac and Linux read it with.
    private let history: HistoryStore
    /// What sites were allowed, and what they are asking right now. The Mac's object, out of
    /// `SixCore`: the memory, the queue and the suspended page are shared code, and only the shape a
    /// request arrives in is this front's (`RailWebView.onMediaRequest`).
    private let permissions: SitePermissions
    /// Told when a question appears or is answered. A question arrives from a WebKit callback and
    /// moves nothing the window would otherwise repaint for.
    public var onPermissionQuestion: (() -> Void)?
    /// Where a column's picture is kept once its page has been given back.
    private let thumbnailFolder: URL

    private init() {
        // The same two tables the Mac reads, in the same file — `AppSupport.root` answers
        // `%LOCALAPPDATA%\six` here. An empty table is a new browser and is read as one
        // (`ProfileStore`), which is where the two defaults below come from.
        //
        // Fatal, the way `sixApp` treats it and unlike the Linux front, because of what a profile
        // *is*: the id every cookie jar, visit and bookmark is keyed by. A front that carried on
        // without the table would mint fresh ids on every launch, point WebKit at folders named
        // after them, and leave the real site data on disk under names nothing looks up any more -
        // every login gone, and nothing said. Linux can step over its own database because all it
        // loses is history; here the loss is silent and permanent, so this stops and says where to
        // look.
        // Before the first connection exists, because that is what a SQLite auto extension means:
        // it reaches the connections opened after it and no others. `Vectors` has the whole of why.
        Vectors.register()
        do {
            let database = try AppDatabase.open()
            Vectors.selfTestIfAsked(database)
            settings = SettingsStore(database: database)
            SettingsStore.shared = settings
            profileStore = ProfileStore(database: database)
            history = HistoryStore(database: database)
            permissions = SitePermissions(settings: settings)
            // Written down the first time rather than recomputed, so that an update which moves the
            // recommendation does not re-embed somebody's library behind their back — the Mac's
            // `sixApp` makes the same decision in the same order, and for the same reason.
            let choice = settings.embeddingModel ?? EmbeddingModelChoice.recommended
            if settings.embeddingModel == nil { settings.embeddingModel = choice }
            let indexer = BookmarkIndexer(database: database, choice: choice)
            // Read from the rows rather than from `self`, which does not exist yet: a copy is kept
            // in the folder the profile's cookies are already beside, by the same naming rule.
            let rows = ProfileStore(database: database)
            indexer.profileFolder = { id in
                rows.all().first { $0.id == id }.map { Self.profileFolder(named: $0.name, id: $0.id) }
            }
            bookmarks = indexer
        } catch {
            fatalError("six: cannot open \(AppDatabase.url.path): \(error)")
        }
        thumbnailFolder = AppSupport.folder("Thumbnails")
        try? FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)

        // A private profile's answers live as long as the profile and are written nowhere — the
        // same rule as its cookies, and for the same reason.
        permissions.isPrivate = { [weak self] id in self?.privateProfile?.id == id }
        permissions.onQuestionsChanged = { [weak self] in self?.onPermissionQuestion?() }

        profileRecords = profileStore.all()
        if profileRecords.isEmpty {
            profileRecords = Self.defaultProfiles
            profileStore.save(profileRecords)
        }
        // Where the browser was left. An id that names no row falls back to the first profile
        // rather than to nothing: a profile can be removed by a front that has a way to remove one.
        selectedProfileID = profileRecords.first { $0.id == settings.selectedProfileID }?.id
            ?? profileRecords[0].id
        layout.activeProfileID = selectedProfileID

        if !restore() {
            openColumn() // a window to land on, the way every front starts
        } else if let requested = ProcessInfo.processInfo.environment["SIX_URL"] {
            // A run pointed at a test page lands on it, restored rail or not — otherwise `SIX_URL`
            // would stop meaning anything the first time six had been used.
            openColumn(url: requested)
        }
        pruneThumbnails()
    }

    // MARK: Profiles

    /// A profile as this front needs it: what to draw in the chip, and where its cookies go.
    ///
    /// Not `Profile` — that type carries a SwiftUI `Color` and stays in the Mac app. What crosses
    /// into `SixCore`, and therefore reaches Windows, is the row: `ProfileRecord`. The folder is
    /// computed here for the same reason, by the same rule the Mac's `Profile.folder` uses.
    public struct ProfileInfo: Identifiable, Sendable {
        public let id: UUID
        public var name: String
        public var colorHex: String
        public var isPrivate: Bool
        /// Native path of the folder this profile's site data lives in.
        public var storageFolder: String
    }

    /// The two profiles a new browser starts with, and the colours a new one is given, are the Mac's
    /// own (`Profile.defaults`, `ProfilePopover.palette`). English rather than localized: this front
    /// has no string catalog yet, and the rail's own "New Tab" is already in the same boat.
    private static let palette = ["#5B8DEF", "#E8743B", "#38A169", "#9F7AEA",
                                  "#E05252", "#D69E2E", "#2C9C9C", "#D45B9A"]

    private static var defaultProfiles: [ProfileRecord] {
        [ProfileRecord(id: UUID(), name: "Personal", colorHex: palette[0], dataStoreID: UUID(), ord: 0),
         ProfileRecord(id: UUID(), name: "Work", colorHex: palette[1], dataStoreID: UUID(), ord: 1)]
    }

    public var profiles: [ProfileInfo] {
        profileRecords.map(Self.info(for:)) + (privateProfile.map { [$0] } ?? [])
    }

    public var activeProfile: ProfileInfo {
        profiles.first { $0.id == selectedProfileID } ?? Self.info(for: profileRecords[0])
    }

    private static func info(for record: ProfileRecord) -> ProfileInfo {
        ProfileInfo(id: record.id, name: record.name, colorHex: record.colorHex, isPrivate: false,
                    storageFolder: storageFolder(named: record.name, id: record.id))
    }

    /// `Profiles/<name>/WebKit`, beside the bookmarks and the scratchpad the Mac keeps in that same
    /// folder, with the id standing in for a name that is empty or all separators.
    private static func storageFolder(named name: String, id: UUID) -> String {
        nativePath(profileFolder(named: name, id: id).appending(path: "WebKit", directoryHint: .isDirectory))
    }

    /// `Profiles/<name>`: the site data, the bookmarks' Markdown copies and, one day, the scratchpad.
    private static func profileFolder(named name: String, id: UUID) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return AppSupport.folder("Profiles/\(safe.isEmpty ? id.uuidString : safe)")
    }

    /// The native spelling, not `URL.path`: these strings are handed to WebKit, to GDI and to
    /// `FileManager` on a platform whose separator is not the one a file URL prints.
    private static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { String(cString: $0) } ?? url.path
        }
    }

    /// A profile whose rail is empty stays empty when it comes up — the Mac's rule
    /// (`BrowserState.selectProfile`): otherwise stepping away and back would put the start page
    /// right back where closing the last column had just taken it from.
    public func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        layout.activeProfileID = id
        // The private profile is deliberately not written down: it is in no table, and a relaunch
        // that came back into it would be a private session outliving the process it was private to.
        // The Mac's snapshot keeps the last non-private profile for the same reason.
        if privateProfile?.id != id { settings.selectedProfileID = id }
    }

    /// A profile just made is a different matter: it was asked for in order to browse in it, so it
    /// opens with a window the way a new browser does.
    public func addProfile() {
        let record = ProfileRecord(id: UUID(), name: "Profile \(profileRecords.count + 1)",
                                   colorHex: Self.palette[profileRecords.count % Self.palette.count],
                                   dataStoreID: UUID(), ord: profileRecords.count)
        profileRecords.append(record)
        profileStore.save(profileRecords)
        selectProfile(record.id)
        openColumn()
    }

    /// Private browsing: a profile written down nowhere, whose site data never reaches the disk
    /// (`WebEngine` gives it the non-persistent store). It lives until six quits, which is the whole
    /// of what "private" means on this front.
    public func selectPrivateProfile() {
        if privateProfile == nil {
            privateProfile = ProfileInfo(id: UUID(), name: "Private", colorHex: "#5C5C66",
                                         isPrivate: true, storageFolder: "")
        }
        guard let privateProfile else { return }
        let isEmpty = layout.strip(for: privateProfile.id).workspaces.allSatisfy { $0.columns.isEmpty }
        selectProfile(privateProfile.id)
        if isEmpty { openColumn() }
    }

    /// Every column in every profile — how `RailLiveView` tells a column that was closed from one
    /// that is merely out of sight in another profile's strip.
    public var allTabIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for strip in layout.allStrips.values {
            for workspace in strip.workspaces {
                ids.formUnion(workspace.columns.flatMap(\.tabIDs))
            }
        }
        return ids
    }

    /// Which profile a column belongs to. A live page of a profile that is not on screen can still
    /// finish loading, and the visit it records is that profile's, not the one being looked at.
    private func profileID(of tabID: UUID) -> UUID? {
        layout.allStrips.first { _, strip in
            strip.workspaces.contains { workspace in workspace.columns.contains { $0.holds(tabID) } }
        }?.key
    }

    /// The profile a column's page browses in — its cookies, its storage.
    public func profile(of tabID: UUID) -> ProfileInfo {
        let id = profileID(of: tabID)
        return profiles.first { $0.id == id } ?? activeProfile
    }

    private func isPrivate(_ tabID: UUID) -> Bool {
        guard let privateProfile else { return false }
        return profileID(of: tabID) == privateProfile.id
    }

    // MARK: What the strip draws

    public var columns: [Column] {
        guard let workspace = layout.focusedWorkspace else { return [] }
        let scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview
        // One entry per *window*, which is what `placements` is for: a column holds one window or
        // two side by side. Nothing on this front makes a split yet, but a strip restored from the
        // settings table can arrive with one, and a half that is not drawn is a window nobody can
        // reach.
        return layout.placements(workspace.columns).map { place in
            Column(id: place.tabID, frame: place.frame.offsetBy(dx: -scroll, dy: 0),
                   title: titles[place.tabID] ?? "",
                   isFocused: place.tabID == layout.focusedTabID,
                   permission: question(for: place.tabID))
        }
    }

    public var focusedTabID: UUID? { layout.focusedTabID }
    public var gap: Double { Double(layout.gap) }
    public var columnSize: CGSize { CGSize(width: layout.columnWidth, height: layout.columnHeight) }
    public var workspaceCount: Int { layout.workspaces.count }
    public var focusedWorkspaceIndex: Int { layout.focusedWorkspaceIndex }
    public var workspaceTitle: String { layout.title(at: layout.focusedWorkspaceIndex) }
    /// What the pips in the top bar draw: an empty workspace is outlined rather than filled, the way
    /// `WorkspacePips` shows it on the Mac.
    public func isWorkspaceEmpty(at index: Int) -> Bool {
        guard layout.workspaces.indices.contains(index) else { return true }
        return layout.workspaces[index].columns.isEmpty
    }

    @discardableResult
    public func updateViewport(_ size: CGSize) -> Bool {
        guard size.width > 1, size.height > 1, size != layout.viewport else { return false }
        layout.updateViewport(size)
        return true
    }

    // MARK: Overview

    /// The whole strip at once, every workspace stacked, scaled down — a way of *looking* at the rail
    /// rather than a second arrangement of it, which is the Mac's `NiriStripView` reading of the same
    /// state and the Linux front's `GskTransform`.
    public var isOverview: Bool { layout.isOverview }
    public func toggleOverview() { layout.isOverview.toggle() }
    public func leaveOverview() { layout.isOverview = false }
    public var overviewScale: Double { Double(layout.overviewScale) }

    /// The Mac's geometry, point for point: each workspace a row at `rowY`, each row centred on the
    /// window by `canvasX`, and the whole canvas scaled about the window's centre — which is exactly
    /// what `.scaleEffect(layout.overviewScale, anchor: .center)` does to it there.
    public var overviewCards: [OverviewCard] {
        guard layout.isOverview else { return [] }
        var cards: [OverviewCard] = []
        for (index, workspace) in layout.workspaces.enumerated() {
            let rowY = layout.rowY(index)
            for place in layout.placements(workspace.columns) {
                let x = layout.canvasX(content: place.frame.minX, workspace: index)
                let frame = CGRect(x: x, y: rowY + place.frame.minY,
                                   width: place.frame.width, height: place.frame.height)
                cards.append(OverviewCard(id: place.tabID, frame: scaledForOverview(frame),
                                          title: titles[place.tabID] ?? "",
                                          isFocused: place.tabID == layout.focusedTabID))
            }
        }
        return cards
    }

    /// Where each workspace's name goes: just above the top-left corner of its row, the place the
    /// Mac's `WorkspacePlates` puts it.
    public var overviewRows: [OverviewRow] {
        guard layout.isOverview else { return [] }
        return layout.workspaces.indices.map { index in
            let corner = scaledForOverview(CGRect(
                x: layout.canvasX(content: layout.outerGap, workspace: index),
                y: layout.rowY(index) + layout.outerGap, width: 0, height: 0))
            return OverviewRow(index: index, title: layout.title(at: index),
                               left: Double(corner.minX), top: Double(corner.minY),
                               isFocused: index == layout.focusedWorkspaceIndex)
        }
    }

    private func scaledForOverview(_ rect: CGRect) -> CGRect {
        let scale = layout.overviewScale
        let centre = CGPoint(x: layout.viewport.width / 2, y: layout.viewport.height / 2)
        return CGRect(x: centre.x + (rect.minX - centre.x) * scale,
                      y: centre.y + (rect.minY - centre.y) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: Live pages

    /// Decide which columns keep their `WKView`: what the strip is showing plus half a screen either
    /// side is pinned, everything else lives or dies by the budget — against every column of every
    /// profile, because a hidden view of the workspace above is one keystroke from being wanted
    /// again and costs nothing while it is in budget. The overview pins nothing: it draws pictures.
    public func settleLivePages() -> (live: Set<UUID>, dropped: Set<UUID>) {
        let pinned = layout.isOverview ? [] : layout.visibleTabIDs
        let dropped = pages.settle(pinned: pinned, all: Array(allTabIDs))
        return (pages.live, dropped)
    }

    public var liveBudget: Int { pages.budget }

    // MARK: Opening and closing

    public func openColumn() {
        openColumn(url: nil)
    }

    /// A column on an address of its own — a row of the history, or `SIX_URL` over a restored rail.
    public func openColumn(url: String?) {
        let tabID = UUID()
        titles[tabID] = "New Tab \(nextTabNumber)"
        nextTabNumber += 1
        if let url { urls[tabID] = url }
        layout.insertColumn(tabID: tabID)
        changed()
    }

    /// A column a page asked for: a window it opened (`window.open`, `target=_blank`), in front; or a
    /// link that was middle- or `Ctrl`-clicked, behind, with the focus left where it was — the Mac's
    /// `openInNewWindow(_:from:background:)`. Right of the focused column, which is the one that asked
    /// unless a page in the background opened a window, and then it goes where the reader is; in the
    /// asking column's profile, whose cookies the new page shares.
    @discardableResult
    public func openColumn(url: String?, from source: UUID, focus: Bool) -> UUID {
        let tabID = UUID()
        titles[tabID] = "New Tab \(nextTabNumber)"
        nextTabNumber += 1
        if let url, !url.isEmpty { urls[tabID] = url }
        layout.insertColumn(tabID: tabID, in: profile(of: source).id, focus: focus)
        changed()
        return tabID
    }

    public func closeColumn(_ tabID: UUID? = nil) {
        guard let target = tabID ?? layout.focusedTabID else { return }
        layout.removeColumn(tabID: target)
        titles[target] = nil
        urls[target] = nil
        pages.forget(target)
        // The page is suspended inside `getUserMedia()`; a promise that never lands is a page that
        // never finds out. Denying is the answer a closed column gives.
        permissions.forget(target)
        try? FileManager.default.removeItem(atPath: thumbnailPath(for: target))
        changed()
    }

    /// The column's page was given back to the budget. It keeps its place; a question it was
    /// asking is answered no, because the page that asked is gone.
    public func pageDiscarded(_ tabID: UUID) {
        permissions.forget(tabID)
    }

    // MARK: What a live column loads

    /// Where a column is, or the start page for one that has not reported anywhere yet — `RailWindow`
    /// asks this exactly once, the moment a column's `WKView` is created.
    public func url(for tabID: UUID) -> String { urls[tabID] ?? Self.startURL }

    public func title(for tabID: UUID) -> String { titles[tabID] ?? "" }

    /// Told by the page itself once it has actually navigated somewhere — not called for the start
    /// page a fresh column merely defaults to, since nothing has loaded yet at that point.
    public func setURL(_ url: String, for tabID: UUID) {
        guard urls[tabID] != url else { return }
        urls[tabID] = url
        save()
    }

    /// Told by the page once it has a real title — empty titles are the caller's business to filter
    /// (a page mid-load has none), not this method's. The visit that is already in the table gets it
    /// too: titles usually arrive after the navigation commits.
    public func setTitle(_ title: String, for tabID: UUID) {
        let changed = titles[tabID] != title
        let awaited = !title.isEmpty && awaitingTitle.remove(tabID) != nil
        guard changed || awaited else { return }
        titles[tabID] = title
        if !title.isEmpty, !isPrivate(tabID), let profile = profileID(of: tabID),
           let url = urls[tabID].flatMap(URL.init(string:)) {
            history.updateTitle(title, for: url, in: profile)
        }
        if changed { save() }
    }

    /// Whether the visit a column just recorded is still waiting for its title, so the poll hands
    /// the page's title over even when it is the one the card already shows. A restored column
    /// reloading the page it was on is exactly that case: the title is not new to the rail, only to
    /// the visit — which was otherwise left named by its address.
    public func awaitsTitle(_ tabID: UUID) -> Bool { awaitingTitle.contains(tabID) }

    /// A navigation finished: that is a visit, in the profile the column belongs to — unless that
    /// profile is private, which records nothing. Translation does not look at this; reading a page
    /// is not the same as recording that it was read.
    public func pageDidFinishLoading(_ tabID: UUID, url: String, title: String) {
        if !url.isEmpty { setURL(url, for: tabID) }
        guard !isPrivate(tabID), let profile = profileID(of: tabID),
              let address = URL(string: self.url(for: tabID)) else { return }
        history.record(address, title: title, in: profile)
        // `didFinishNavigation` is not the moment a title exists — see `RailWebView.title` — so the
        // title the poll reads next is the one the visit gets.
        awaitingTitle.insert(tabID)
    }

    // MARK: Focus and the strip

    public func focus(_ tabID: UUID) {
        guard layout.focusedTabID != tabID else { return }
        layout.focus(tabID: tabID)
        changed()
    }
    public func focusColumn(_ delta: Int) { layout.focusColumn(delta); changed() }
    public func canFocusColumn(_ delta: Int) -> Bool { layout.canFocusColumn(delta) }
    public func focusColumnEdge(last: Bool) { layout.focusColumnEdge(last: last); changed() }
    public func moveColumn(_ delta: Int) { layout.moveColumn(delta); changed() }
    public func focusWorkspace(_ delta: Int) { layout.focusWorkspace(delta); changed() }
    public func canFocusWorkspace(_ delta: Int) -> Bool { layout.canFocusWorkspace(delta) }
    public func focusWorkspace(at index: Int) { layout.focusWorkspace(at: index); changed() }
    public func moveColumnToWorkspace(_ delta: Int) { layout.moveColumnToWorkspace(delta); changed() }
    public func panStrip(by delta: CGFloat) { layout.panStrip(by: delta) }
    public func snapFocusToView() { layout.snapFocusToView() }
    public func previewColumn(_ amount: CGFloat) { layout.previewColumn(amount) }
    public func previewWorkspace(_ amount: CGFloat) { layout.previewWorkspace(amount) }
    public func toggleCenterFocus() { layout.setCentersFocus(!layout.centersFocus) }
    public func toggleFullWidth() { layout.setFill(layout.showsFill == .tiled ? .window : .tiled) }
    public var isFullWidth: Bool { layout.showsFill == .window }

    /// Anything that moved the strip: the focused column is the warmest page there is, and the
    /// shape is written down now rather than on quit, because a browser that only saves on quit
    /// loses everything to the one crash it was going to have.
    private func changed() {
        if let focused = layout.focusedTabID { pages.touch(focused) }
        save()
    }

    // MARK: Leaving and coming back

    /// Put every profile's strip back the way it was left. Returns whether there was anything to put
    /// back; if not, the caller opens a first window instead.
    ///
    /// Which profile is on screen is not read from here but from `profile.selected`, which already
    /// said so before there was a strip to restore — one record of one fact.
    private func restore() -> Bool {
        guard let state = StripState.load(from: settings), state.isWorthKeeping else { return false }
        let known = Set(profileRecords.map(\.id))
        var strips: [UUID: NiriStrip] = [:]
        for (key, strip) in state.strips {
            // A strip of a profile that no longer has a row is a strip nobody can switch to.
            if let id = UUID(uuidString: key), known.contains(id) { strips[id] = strip }
        }
        guard !strips.isEmpty else { return false }
        layout.restore(strips: strips)
        layout.activeProfileID = selectedProfileID
        for (key, value) in state.urls { if let id = UUID(uuidString: key) { urls[id] = value } }
        for (key, value) in state.titles { if let id = UUID(uuidString: key) { titles[id] = value } }
        nextTabNumber = titles.count + 1
        Log.info(.storage, "restored \(allTabIDs.count) columns in \(strips.count) profiles")
        return true
    }

    /// Every strip but the private one's: it is recorded nowhere by definition, and a relaunch must
    /// not bring it back — the Mac's snapshot filters `profiles.filter { !$0.isPrivate }` for the
    /// same reason.
    private func save() {
        var state = StripState()
        var kept: Set<UUID> = []
        for (id, strip) in layout.allStrips where id != privateProfile?.id {
            state.strips[id.uuidString] = strip
            for workspace in strip.workspaces { kept.formUnion(workspace.columns.flatMap(\.tabIDs)) }
        }
        for (id, url) in urls where kept.contains(id) { state.urls[id.uuidString] = url }
        for (id, title) in titles where kept.contains(id) && !title.isEmpty { state.titles[id.uuidString] = title }
        state.activeProfile = settings.selectedProfileID?.uuidString ?? ""
        state.save(to: settings)
    }

    // MARK: Thumbnails

    /// A picture of a page, so a column that has given up its `WKView` — or the overview, which
    /// shows every column at once — still has something to draw. A 32-bit BMP, because GDI can
    /// both write and load one with nothing but itself; the Mac and Linux keep PNGs under the same
    /// folder name.
    public func thumbnailPath(for tabID: UUID) -> String {
        Self.nativePath(thumbnailFolder.appendingPathComponent(tabID.uuidString + ".bmp"))
    }

    /// One file per column that still exists, and no more — otherwise the folder grows without end.
    private func pruneThumbnails() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: thumbnailFolder, includingPropertiesForKeys: nil) else { return }
        let open = allTabIDs
        for file in files where file.pathExtension == "bmp" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !open.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: History

    /// A visit, flattened for the list: what to call it, where it went, and the address to open.
    public struct HistoryRow: Identifiable {
        public let id: String
        public let url: String
        public let title: String
        public let detail: String
    }

    /// Empty query means the recent ones, one per page; anything else is a search. Both are queries
    /// against the `visits` table through `HistoryStore`, scoped to the profile on screen — the list
    /// does not filter something it holds in memory, because history outlives what fits in one. A
    /// private profile has none to show.
    public func history(matching query: String) -> [HistoryRow] {
        guard !activeProfile.isPrivate else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visits = trimmed.isEmpty
            ? history.recent(in: activeProfile.id, limit: 200)
            : Array(history.search(trimmed, in: activeProfile.id).prefix(500))
        return visits.map {
            HistoryRow(id: $0.id.uuidString, url: $0.url.absoluteString,
                       title: $0.displayTitle, detail: $0.displayDetail)
        }
    }

    // MARK: Site permissions

    /// A page asked for the camera or the microphone. Everything past the translation into
    /// `SitePermission`s is the Mac's — the remembered answer, the queue, the suspended page.
    public func requestMedia(tabID: UUID, origin: String, camera: Bool, microphone: Bool,
                             answer: @escaping (Bool) -> Void) {
        var asked: [SitePermission] = []
        if camera { asked.append(.camera) }
        if microphone { asked.append(.microphone) }
        guard let profile = profileID(of: tabID) else { return answer(false) }
        Log.info(.browser, "permission \(origin) \(asked.map(\.rawValue).joined(separator: "+"))")
        permissions.decide(asked, origin: origin, in: tabID, profileID: profile, then: answer)
    }

    /// `SIX_PERMISSION_SELFTEST=1`: the first page to finish loading asks for the camera and the
    /// microphone as if it had called `getUserMedia()` — through `requestMedia`, so everything from
    /// there on is the real path: the bar, the answer, the memory, the Site Permissions list, and a
    /// page that asks again being answered from memory. What it cannot reach is the one callback
    /// `RailWebView` installs, because the engine this front runs has no MediaStream to call it
    /// with (`WebEngine.makeView`).
    public func permissionSelfTestIfAsked(_ tabID: UUID) {
        // The focused column's page, not merely the first: the margin columns either side load too,
        // and a question put to a page nobody can see is a bar nobody can answer.
        guard ProcessInfo.processInfo.environment["SIX_PERMISSION_SELFTEST"] == "1",
              !permissionSelfTestRan, tabID == layout.focusedTabID,
              let origin = SitePermissions.origin(of: URL(string: url(for: tabID))) else { return }
        permissionSelfTestRan = true
        requestMedia(tabID: tabID, origin: origin, camera: true, microphone: true) { allowed in
            Log.info(.browser, "permission self-test: \(origin) answered \(allowed ? "allow" : "block")")
        }
    }
    private var permissionSelfTestRan = false

    /// The bar's two buttons. Remembers the answer and lets the page go.
    public func answerPermission(_ allowed: Bool, for tabID: UUID) {
        permissions.answer(allowed, for: tabID)
    }

    private func question(for tabID: UUID) -> PermissionQuestion? {
        guard let question = permissions.question(for: tabID) else { return nil }
        return PermissionQuestion(
            host: question.host,
            // `ListFormatter` is Apple Foundation's, and this list is never longer than two.
            devices: question.permissions.map(\.label).joined(separator: " and "),
            wantsCamera: question.permissions.contains(.camera))
    }

    /// Every site with a remembered answer — the Mac's Site Permissions panel, flattened.
    public struct PermissionRow: Identifiable {
        public let id: String
        public let origin: String
        public let detail: String
    }

    public var permissionSites: [PermissionRow] {
        permissions.sites.map { site in
            let decided = permissions.decisions(forOrigin: site.origin, profileID: site.profileID)
            let answers = SitePermission.allCases.compactMap { permission -> String? in
                guard let allowed = decided[permission] else { return nil }
                return "\(permission.label) \(allowed ? "allowed" : "blocked")"
            }
            // The same site can be answered differently in two profiles, so the row says whose
            // answer it is.
            let profile = profileRecords.first { $0.id == site.profileID }?.name ?? "Private"
            return PermissionRow(id: site.id, origin: site.origin,
                                 detail: "\(profile) · " + answers.joined(separator: ", "))
        }
    }

    /// Take it back: the site asks again the next time it needs a device.
    public func forgetPermissions(_ id: String) {
        guard let site = permissions.sites.first(where: { $0.id == id }) else { return }
        permissions.forget(origin: site.origin, profileID: site.profileID)
    }
}
