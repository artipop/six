import Foundation
import GRDB

@testable internal import SixCore

/// The rail's own state: `NiriLayout` plus what a column needs to draw itself and, once it is
/// live, to load.
///
/// The profiles are the same two tables the Mac reads, in the same file, and which one is on screen
/// outlives the process; the strip itself does not yet — see `docs/windows.md`. The rail and its
/// mechanics — open, close, focus, move, the workspaces stacked above and below it — are the same
/// shape here as on every other front because `NiriLayout` is the same code, unchanged, imported
/// the way the Linux front already does: `@testable` because its members are `internal` and were
/// never meant to be a public API, only a shared one — SwiftPM enables testability for debug
/// builds across the whole graph, which is what makes this legal.
///
/// The overview (⌥O on the Mac) is deliberately not in here: it is a second way of *drawing* the
/// same strip, and this front does not draw it yet. `NiriLayout.isOverview` exists and would flip
/// happily, but a toggle nothing on screen answers to is worse than no toggle — see docs/windows.md.
public final class RailModel {
    /// A column, flattened for the view: its on-screen frame and what to write on it.
    public struct Column: Identifiable {
        public let id: UUID
        public var frame: CGRect
        public var title: String
        public var isFocused: Bool
    }

    /// The same address `linux/Sources/SixBrowser/BrowserModel` opens a fresh column on, and the
    /// same `SIX_URL` override — the only way to point a run at a test page without a keyboard.
    public static let startURL = ProcessInfo.processInfo.environment["SIX_URL"] ?? "https://duckduckgo.com/"

    public static let shared = RailModel()

    let layout = NiriLayout()
    private var titles: [UUID: String] = [:]
    private var urls: [UUID: String] = [:]
    private var nextTabNumber = 1

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
            // Written down the first time rather than recomputed, so that an update which moves the
            // recommendation does not re-embed somebody's library behind their back — the Mac's
            // `sixApp` makes the same decision in the same order, and for the same reason.
            let choice = settings.embeddingModel ?? EmbeddingModelChoice.recommended
            if settings.embeddingModel == nil { settings.embeddingModel = choice }
            bookmarks = BookmarkIndexer(database: database, choice: choice)
        } catch {
            fatalError("six: cannot open \(AppDatabase.url.path): \(error)")
        }
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
        openColumn() // a window to land on, the way every front starts
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
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let url = AppSupport.folder("Profiles/\(safe.isEmpty ? id.uuidString : safe)/WebKit")
        // The native spelling, not `URL.path`: this string is handed to WebKit and to `FileManager`
        // on a platform whose separator is not the one a file URL prints.
        return url.withUnsafeFileSystemRepresentation { pointer in
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
        for profile in profiles {
            for workspace in layout.strip(for: profile.id).workspaces {
                ids.formUnion(workspace.columns.map(\.tabID))
            }
        }
        return ids
    }

    // MARK: What the strip draws

    public var columns: [Column] {
        guard let workspace = layout.focusedWorkspace else { return [] }
        let frames = layout.columnFrames(workspace)
        let scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview
        return workspace.columns.enumerated().compactMap { index, column in
            guard frames.indices.contains(index) else { return nil }
            let frame = frames[index].offsetBy(dx: -scroll, dy: 0)
            return Column(id: column.tabID, frame: frame, title: titles[column.tabID] ?? "",
                          isFocused: column.tabID == layout.focusedTabID)
        }
    }

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

    // MARK: Opening and closing

    public func openColumn() {
        let tabID = UUID()
        titles[tabID] = "New Tab \(nextTabNumber)"
        nextTabNumber += 1
        layout.insertColumn(tabID: tabID)
    }

    public func closeColumn(_ tabID: UUID? = nil) {
        guard let target = tabID ?? layout.focusedTabID else { return }
        layout.removeColumn(tabID: target)
        titles[target] = nil
        urls[target] = nil
    }

    // MARK: What a live column loads

    /// Where a column is, or the start page for one that has not reported anywhere yet — `RailWindow`
    /// asks this exactly once, the moment a column's `WKView` is created.
    public func url(for tabID: UUID) -> String { urls[tabID] ?? Self.startURL }

    /// Told by the page itself once it has actually navigated somewhere — not called for the start
    /// page a fresh column merely defaults to, since nothing has loaded yet at that point.
    public func setURL(_ url: String, for tabID: UUID) { urls[tabID] = url }

    /// Told by the page once a navigation finishes and it has a real title — empty titles are the
    /// caller's business to filter (a page mid-load has none), not this method's.
    public func setTitle(_ title: String, for tabID: UUID) { titles[tabID] = title }

    // MARK: Focus and the strip

    public func focus(_ tabID: UUID) { layout.focus(tabID: tabID) }
    public func focusColumn(_ delta: Int) { layout.focusColumn(delta) }
    public func canFocusColumn(_ delta: Int) -> Bool { layout.canFocusColumn(delta) }
    public func focusColumnEdge(last: Bool) { layout.focusColumnEdge(last: last) }
    public func moveColumn(_ delta: Int) { layout.moveColumn(delta) }
    public func focusWorkspace(_ delta: Int) { layout.focusWorkspace(delta) }
    public func canFocusWorkspace(_ delta: Int) -> Bool { layout.canFocusWorkspace(delta) }
    public func focusWorkspace(at index: Int) { layout.focusWorkspace(at: index) }
    public func moveColumnToWorkspace(_ delta: Int) { layout.moveColumnToWorkspace(delta) }
    public func panStrip(by delta: CGFloat) { layout.panStrip(by: delta) }
    public func snapFocusToView() { layout.snapFocusToView() }
    public func previewColumn(_ amount: CGFloat) { layout.previewColumn(amount) }
    public func previewWorkspace(_ amount: CGFloat) { layout.previewWorkspace(amount) }
    public func toggleCenterFocus() { layout.setCentersFocus(!layout.centersFocus) }
    public func toggleFullWidth() { layout.setFill(layout.showsFill == .tiled ? .window : .tiled) }
    public var isFullWidth: Bool { layout.showsFill == .window }
}
