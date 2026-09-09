import Foundation
import Observation
#if canImport(SwiftUI)
import SwiftUI
#else
// The strip's geometry is the one piece a second front end reuses whole, and the only thing standing
// between it and a Linux build was three lines of animation. The model's business is *when* something
// should ease rather than jump; how it eases belongs to whoever draws it, and GTK has a timeline of
// its own. So off Apple these stand in, the call sites stay identical on both platforms, and the
// front animates the properties it reads.
struct Animation: Sendable {
    static func smooth(duration: Double, extraBounce: Double = 0) -> Animation { Animation() }
}

func withAnimation<Result>(_ animation: Animation? = nil, _ body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

// MARK: - Model

/// One window in the strip — or two of them, side by side.
///
/// A column is one screen's worth of rail whether it holds one window or two: a split shares the
/// width one window would have had, with a gap down the middle half the size of the one between
/// columns, so the pair reads as belonging to each other rather than as two neighbours on the rail.
///
/// niri splits a column the other way — its windows stack vertically — and that is right for
/// terminals and wrong for pages. A web page is tall; two half-height ones are two pages nobody can
/// read. Side by side is what a person means by a split screen, and what an article and its source,
/// or a document and the page it is being written from, are for.
///
/// **Two is the ceiling, on purpose.** Three pages at a third of a screen each are three unreadable
/// pages, and wanting more than two things at once is the question the rail already answers.
nonisolated struct NiriColumn: Identifiable, Hashable, Sendable, Codable {
    /// The column's own identity, and deliberately not its window's.
    ///
    /// A split that loses a half is the same column with one window left in it; a half taken out
    /// into a column of its own is a column that has just arrived. The view tree has to be able to
    /// tell those apart — a window is a `WebView` over a `WebPage`, of which WebKit allows exactly
    /// one, so a column that appears to leave and arrive draws its page twice and traps
    /// (`unanimated` has the rest of that story). Identified by the window it held, as it was when
    /// it could only hold one, every split and unsplit was one of those.
    var id = UUID()
    /// The window on the left, and the only one unless the column is split.
    var tabID: UUID
    /// The window sharing the column, on the right.
    var second: UUID?
    /// Which half the focus is in: 0 for `tabID`, 1 for `second`. Everything keyed off the selection
    /// — the address field, ⌘W, the assistant, ⌃Tab — points at that one.
    var pane: Int = 0

    init(id: UUID = UUID(), tabID: UUID, second: UUID? = nil, pane: Int = 0) {
        self.id = id
        self.tabID = tabID
        self.second = second
        self.pane = pane
    }

    /// The windows in it, left to right.
    var tabIDs: [UUID] { second.map { [tabID, $0] } ?? [tabID] }
    var isSplit: Bool { second != nil }
    /// The focused half's window — which is the whole of what a column meant before it could split.
    var focusedTabID: UUID { pane == 1 ? (second ?? tabID) : tabID }
    func holds(_ id: UUID) -> Bool { tabID == id || second == id }
    func paneIndex(of id: UUID) -> Int? { tabID == id ? 0 : (second == id ? 1 : nil) }

    /// Puts a second window in the column, on a side, and leaves the focus on the window that was
    /// already there — ⌥S is pressed while reading something, and the reading is not what moves.
    /// The side keeps the order the rail had: a window pulled in from the left arrives on the left.
    mutating func insert(_ id: UUID, on side: NiriPlacement) {
        guard second == nil else { return }
        switch side {
        case .right:
            second = id
        case .left:
            second = tabID
            tabID = id
            pane = 1
        }
    }

    /// Takes a window out, and says whether the column still has one. `false` is the column going
    /// with it.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        switch paneIndex(of: id) {
        case 0:
            guard let second else { return false }
            tabID = second
            self.second = nil
            pane = 0
        case 1:
            second = nil
            pane = 0
        default:
            break
        }
        return true
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, tabID, second, pane
    }

    /// A column on disk was a `tabID` and nothing else until it could hold two, and a session file
    /// outlives the build that wrote it in both directions — so the old shape decodes with the new
    /// halves at their defaults, and a strip saved by a build that splits is still read by one that
    /// does not (it sees the left window and drops the other, which is a window lost and not a
    /// launch lost).
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try values.decode(UUID.self, forKey: .tabID)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        second = try values.decodeIfPresent(UUID.self, forKey: .second)
        pane = try values.decodeIfPresent(Int.self, forKey: .pane) ?? 0
    }
}

/// A niri workspace: an infinite horizontal strip of full-height columns.
nonisolated struct NiriWorkspace: Identifiable, Sendable, Codable {
    var id = UUID()
    /// Optional, like niri's named workspaces. A named workspace does not vanish the moment it runs
    /// out of windows: it is asked about first (`NiriWorkspaceRemoval`), because the name is the one
    /// thing on a rail a person typed and losing it silently is losing work.
    var name: String = ""
    var columns: [NiriColumn] = []
    /// Index of the focused column.
    var focus: Int = 0
    /// Scroll position of the strip, in points of content space.
    var viewOffset: CGFloat = 0

    var isEmpty: Bool { columns.isEmpty }
    var focusedColumn: NiriColumn? { columns.indices.contains(focus) ? columns[focus] : nil }
}

/// How much room the focused window is given, and the whole of what there is to choose. A window is
/// a screen's worth of page in both: the rail leaves it the gaps it needs to read as a card in a row
/// of them, full width takes even those away. There is deliberately nothing smaller — a browser
/// window at two thirds of a screen is a page with a hole beside it, and choosing between four
/// fractions of one is a decision nobody asked for.
///
/// There was a third — a fullscreen that took the top bar too and gave the page every edge, with a
/// bar of its own hiding at the top. It went: it was a second answer to the question full width
/// already answers, it cost the address field and the only way back was a key or a pointer thrown at
/// the top of the screen. A page's own `requestFullscreen` is a separate thing, and not a free one:
/// WebKit hands it out only if the view asked for it (`webViewElementFullscreenBehavior`), which is
/// what the rail's `WebView` does.
nonisolated enum NiriFill: String, Sendable, Codable {
    /// The rail as usual: the gaps, and a window as wide as the screen leaves room for.
    case tiled
    /// The page fills the window under the top bar — no gaps, no title bar. The layout's own controls
    /// stay where they are.
    case window
}

/// Which side of the focused column a new window opens on. Right is niri's own answer and stays the
/// default; left is what the `+` at the near end of the strip asks for, where there is no window to
/// step to and the empty gap used to mean nothing at all.
nonisolated enum NiriPlacement: Equatable, Sendable {
    case left
    case right
}

/// A named workspace that has just lost its last window, and the question that goes with it.
///
/// A row with nothing in it is not worth keeping — that is niri's rule and six's, and it is why an
/// unnamed one disappears the moment its last window does, silently and without asking, a dozen
/// times a day. A *name* is the exception, and not because of who typed it: a name is the only thing
/// on a rail a person put there in words, and taking it away without saying so is taking away work.
///
/// So the rule is the same everywhere and the question is the whole of the difference: the row is
/// gone if the answer is yes, and stands if it is no. `NiriLayout` only asks; how the question looks
/// belongs to whoever draws it.
nonisolated struct NiriWorkspaceRemoval: Identifiable, Sendable, Equatable {
    /// The workspace's own id, so an answer cannot land on a row that has moved.
    var id: UUID
    var name: String
    var profileID: UUID
}

/// Which of a column's windows one is: the whole column, or one half of a split.
nonisolated enum NiriColumnSide: Equatable, Sendable {
    case whole
    case left
    case right
}

/// One window of a row and where it stands, in the row's content space.
///
/// **The strip draws from this and not from the columns**, and that is not a convenience. A window
/// is a `WebView` over a `WebPage`, of which WebKit allows exactly one; a view tree of columns with
/// windows inside them makes a window joining or leaving a split into a view *removed from one
/// container and built in another*, and the second one traps in `makeViewProvider` — measured, from
/// the first press of ⌥S, with `unanimated` around the change and the removal transition gone. Drawn
/// by window, a split is one frame changing into another with the same view in it: nothing is built,
/// nothing is torn down, and the halves slide into place because that is what a frame does.
nonisolated struct NiriWindowPlace: Identifiable, Sendable, Equatable {
    var tabID: UUID
    var frame: CGRect
    var side: NiriColumnSide
    var id: UUID { tabID }
}

/// A side of the canvas, as the rail feels it when there is nothing behind it. Named for the
/// gesture rather than for the screen: `leading` is the end of the rail you scroll back towards,
/// `above` the workspace you scroll up to.
nonisolated enum NiriEdge: Sendable, Hashable, CaseIterable {
    case leading
    case trailing
    case above
    case below
}

/// A window being carried across the overview: where it was picked up, how far the pointer has
/// travelled, and where it would land if it were let go now.
///
/// The strip itself is not touched until the drop. Until then this is what the canvas draws instead:
/// the carried window taken out of the row it came from, a gap of its size held open where it would
/// land, and the card itself following the pointer above both.
nonisolated struct NiriColumnDrag: Sendable, Equatable {
    var tabID: UUID
    var fromWorkspace: Int
    var fromIndex: Int
    var toWorkspace: Int
    var toIndex: Int
    /// The column the carried window would *join*, as its other half, by id — a window let go over
    /// the middle of another rather than in the space beside it. `nil` is the ordinary drop, which
    /// makes a column of its own. By id and not by index because the row the drop lands in is the
    /// row without the carried window in it, and every index past where it stood has moved.
    var joins: UUID?
    /// Which side of the window it would join it lands on: the side it is being held over.
    var joinsSide: NiriPlacement = .right
    /// Pointer travel since the card was picked up, in canvas points (the overview's scale is applied
    /// to the whole canvas afterwards, so these are the same units the column frames are in).
    var translation: CGSize = .zero
    /// The identity the carried window's column has while it is in the air, and keeps when it lands:
    /// the column it was lifted out of when the whole column is moving, a fresh one when it is a half
    /// leaving a split and the column it came from stays behind. See `NiriColumn.id` — a placeholder
    /// whose identity changed at the drop would be a column arriving where one had just left.
    var placeholder = UUID()
    /// The column it was lifted out of, so a half carried straight back onto its own column reads as
    /// having gone nowhere.
    var fromColumn = UUID()

    var movedSomewhere: Bool {
        if let joins { return joins != fromColumn }
        return toWorkspace != fromWorkspace || toIndex != fromIndex
    }
}

/// The vertical stack of workspaces belonging to one profile.
nonisolated struct NiriStrip: Sendable, Codable {
    var workspaces: [NiriWorkspace] = [NiriWorkspace()]
    /// Index of the focused workspace.
    var focus: Int = 0
}

// MARK: - Layout

/// niri-style scrollable tiling: columns laid out left to right in a workspace, workspaces stacked
/// vertically. Owns geometry (column widths, strip scroll offset) and the focus/move operations;
/// `BrowserState` owns the tabs the columns point at.
@MainActor
@Observable
final class NiriLayout {
    /// Gaps are a fraction of the viewport, not a pixel count: the layout should look the same on a
    /// laptop and on a 5K panel. The floor only guards tiny windows. (Control metrics — title bar
    /// heights, buttons, corner radii — stay in points, because text and controls don't scale either.)
    static let gapFraction: CGFloat = 0.01
    static let minimumGap: CGFloat = 10
    /// How far the overview zooms out: enough to show the whole focused strip, but never more than
    /// `overviewBaseScale` (a short strip shouldn't be shrunk for nothing) and never past the floor,
    /// where a long strip starts scrolling instead of getting microscopic.
    static let overviewBaseScale: CGFloat = 0.5
    static let minimumOverviewScale: CGFloat = 0.22
    /// Vertical breathing room between workspaces, as a fraction of the viewport height.
    static let workspaceGapFraction: CGFloat = 0.02
    static let overviewWorkspaceGapFraction: CGFloat = 0.11
    static let switchAnimation: Animation = .smooth(duration: 0.34, extraBounce: 0.05)
    /// How far the strip leans to show something just off its edge: the glance a window opening
    /// behind gets (`peek`), and the ceiling on the one a hovered `+` holds open. A fraction of the
    /// viewport like every other size here — a glance is a proportion of the screen, not a count of
    /// points — with a floor so it stays a glance on a small window.
    static let peekFraction: CGFloat = 0.045
    static let minimumPeek: CGFloat = 56
    /// Deliberately slower than a layout step: nothing has happened yet. The strip is leaning over to
    /// show what *would* happen, and at the speed of a step that reads as the thing itself.
    static let peekAnimation: Animation = .smooth(duration: 0.55)
    /// How far a gesture has to push at an end of the rail for the wall to be fully lit — in points,
    /// like the threshold that produces it, because this is a measure of a finger and not of a
    /// screen: it is `NiriScrollMonitor.threshold` (55) through the rubber band's 0.35, the whole
    /// travel a gesture has before it commits. Everything the wall *draws* is a fraction of the
    /// viewport again; only the push that lights it is a hand's distance.
    static let wallPush: CGFloat = 19
    /// What is left of the rubber band at an end of the rail. A band that gives as freely where there
    /// is nothing behind it as where there is a window says the same thing about both.
    static let wallResistance: CGFloat = 0.4

    /// `SIX_UI_DEBUG=1`: what the layout was asked to do, and what it thought it was doing. A gesture
    /// that does nothing is either not arriving or not meaning what it looks like, and this says which.
    static let tracesUI = ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard tracesUI else { return }
        Log.debug(.ui, message())
    }

    var viewport: CGSize = CGSize(width: 1280, height: 800)
    var isOverview = false
    /// Whether the focused window is given the whole window, as a mode rather than per-window state.
    /// The rail goes on working underneath, so ⌥←/⌥→ walks from one full-width window to the next.
    /// Not macOS fullscreen (the green button), and not a page asking for `requestFullscreen`, which
    /// WebKit handles on its own inside the web view.
    private(set) var fill: NiriFill = .tiled
    /// niri's `center-focused-column`: park the focused window in the middle of the screen instead of
    /// scrolling as little as possible. Off means the rail only moves when the focus would fall off it.
    /// Set from settings by `BrowserState`, which also writes the toggle back.
    var centersFocus = true
    /// Rubber-band offsets while a scroll gesture is still below the switch threshold.
    var verticalPreview: CGFloat = 0
    var horizontalPreview: CGFloat = 0
    /// The pointer resting on one of the strip's edge buttons: -1 for the near end, 1 for the far end,
    /// 0 for neither. The strip leans that way while it is held, showing what is over there — the next
    /// window, or an outline of the one the `+` would open. Deliberately not `horizontalPreview`: that
    /// band belongs to the scroll gesture, and a peek held by the mouse has to survive one arriving.
    var edgeHover = 0
    /// A window being carried across the overview, or `nil`. See `NiriColumnDrag`.
    var columnDrag: NiriColumnDrag?
    /// Named workspaces that have run out of windows and are waiting for an answer, oldest first.
    /// A queue rather than one at a time because closing several windows at once — a profile going
    /// away, a rail being cleared — can empty more than one row, and a question that overwrote
    /// another would delete a workspace nobody was asked about.
    private(set) var pendingRemovals: [NiriWorkspaceRemoval] = []
    /// The one being asked about now.
    var workspaceToRemove: NiriWorkspaceRemoval? { pendingRemovals.first }
    /// The side the rail was last pushed into with nothing behind it, and how brightly it is lit
    /// (0…1). See `hitWall`.
    private(set) var wall: NiriEdge?
    private(set) var wallGlow: CGFloat = 0
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var wallTask: Task<Void, Never>?
    /// The strip on screen. Switching to another profile shows a strip that was last laid out at
    /// whatever the viewport was then, so it gets put back under its focused window on the way in.
    var activeProfileID: UUID = UUID() {
        didSet {
            guard activeProfileID != oldValue else { return }
            recenterStrip(activeProfileID)
        }
    }

    private var strips: [UUID: NiriStrip] = [:]

    // MARK: Access

    var strip: NiriStrip { strips[activeProfileID] ?? NiriStrip() }
    var workspaces: [NiriWorkspace] { strip.workspaces }
    var focusedWorkspaceIndex: Int { min(max(0, strip.focus), max(0, strip.workspaces.count - 1)) }
    var focusedWorkspace: NiriWorkspace? {
        let s = strip
        return s.workspaces.indices.contains(s.focus) ? s.workspaces[s.focus] : nil
    }
    var focusedTabID: UUID? { focusedWorkspace?.focusedColumn?.focusedTabID }
    var hasColumns: Bool { strip.workspaces.contains { !$0.isEmpty } }

    /// Is there a window that way? Drives the on-screen edge buttons, and the wall at the ends of
    /// the rail. A split column is two stops and not one: the step into its other half is a step.
    func canFocusColumn(_ delta: Int) -> Bool {
        guard let ws = focusedWorkspace else { return false }
        if abs(delta) == 1, let column = ws.focusedColumn, column.isSplit,
           column.pane + delta == 0 || column.pane + delta == 1 { return true }
        return ws.columns.indices.contains(ws.focus + delta)
    }

    func canFocusWorkspace(_ delta: Int) -> Bool {
        let s = strip
        return s.workspaces.indices.contains(s.focus + delta)
    }

    /// Vertical distance between two workspaces. Only visible mid-switch — and in the overview,
    /// where it is opened up so the neighbours read as separate screens.
    var workspaceSpacing: CGFloat {
        viewport.height * (isOverview ? Self.overviewWorkspaceGapFraction : Self.workspaceGapFraction)
    }

    private func mutate(_ body: (inout NiriStrip) -> Void) {
        mutate(profile: activeProfileID, body)
    }

    /// Changes made in here are not animated, whatever the caller is animating.
    ///
    /// One thing needs it, and needs it badly: a column moving from one workspace to another. The
    /// row it leaves keeps it alive for the length of its removal transition while the row it joins
    /// builds it again — and a window is a `WebView` over a `WebPage`, of which WebKit allows
    /// exactly one. The second one traps (`EXC_BREAKPOINT` in `_WebKit_SwiftUI`'s
    /// `makeViewProvider`), and ⌥⇧↓ took the whole browser down with it, on the first press, from a
    /// clean launch. No transition, no second view, and the animation that matters — the workspace
    /// sliding up or down — is a separate change and keeps its own.
    private func unanimated(_ body: () -> Void) {
        #if canImport(SwiftUI)
        withTransaction(Transaction(animation: nil), body)
        #else
        body()
        #endif
    }

    private func mutate(profile: UUID, _ body: (inout NiriStrip) -> Void) {
        var s = strips[profile] ?? NiriStrip()
        body(&s)
        normalize(&s)
        strips[profile] = s
        prunePendingRemovals()
    }

    /// Any profile's strip, not just the one on screen — the MCP server lists them all.
    func strip(for profileID: UUID) -> NiriStrip {
        strips[profileID] ?? NiriStrip()
    }

    /// Every strip, for the snapshot.
    var allStrips: [UUID: NiriStrip] { strips }

    /// Replaces every strip with saved ones (normalised, so a stale file can't leave a strip without
    /// its trailing empty workspace or with a focus out of range).
    func restore(strips saved: [UUID: NiriStrip]) {
        strips = [:]
        for (profileID, strip) in saved {
            mutate(profile: profileID) { $0 = strip }
        }
        recenterStrips() // the offsets on disk were written for whatever viewport wrote them
    }

    /// A row has just lost its last window: if it has a name, it becomes a question.
    ///
    /// Every named row asks the same one, whoever the name came from — a person typing into the
    /// plate, a research run naming a workspace after its question, an agent's `workspace: "notes"`.
    /// Guessing which of those is a reservation is exactly what this does not do; the person who is
    /// there answers instead.
    ///
    /// Deliberately here and not in `normalize`: normalize cannot tell a row that has *become* empty
    /// from one that is empty because it was made a moment ago, and every caller of
    /// `workspaceIndex(named:createIfMissing:)` makes a named empty row and fills it on the next
    /// line. Only a row that had something and lost it is worth asking about.
    private func askBeforeRemoving(_ workspace: NiriWorkspace, in profileID: UUID) {
        guard workspace.isEmpty, !workspace.name.isEmpty else { return }
        guard !pendingRemovals.contains(where: { $0.id == workspace.id }) else { return }
        pendingRemovals.append(NiriWorkspaceRemoval(id: workspace.id, name: workspace.name, profileID: profileID))
        NiriLayout.trace("asking about \(workspace.name)")
    }

    /// Yes: the row goes. Guarded on still being empty, because the question outlives the moment it
    /// was asked in — a window can arrive in that row while it is up, and then there is nothing to
    /// remove and the answer is about a workspace that no longer needs one.
    func removeWorkspace(_ id: UUID) {
        // The question is one way in; the plate's own **Delete Workspace** is the other, for a row
        // that was already standing empty when this rule arrived and so was never asked about.
        let profileID = pendingRemovals.first { $0.id == id }?.profileID
            ?? strips.first { $0.value.workspaces.contains { $0.id == id } }?.key
        guard let profileID else { return }
        pendingRemovals.removeAll { $0.id == id }
        mutate(profile: profileID) { s in
            guard let index = s.workspaces.firstIndex(where: { $0.id == id }), s.workspaces[index].isEmpty else { return }
            s.workspaces.remove(at: index)
            s.focus = min(s.focus, max(0, s.workspaces.count - 1))
        }
    }

    /// No: nothing happens. The row stands with its name, the way a named row always has, and is not
    /// asked about again until it is filled and emptied again.
    func keepWorkspace(_ id: UUID) {
        pendingRemovals.removeAll { $0.id == id }
    }

    /// A question is only worth asking while it is still true. A row that was filled again while it
    /// was up, or that went some other way, takes its question with it.
    private func prunePendingRemovals() {
        pendingRemovals.removeAll { pending in
            guard let workspace = strips[pending.profileID]?.workspaces.first(where: { $0.id == pending.id })
            else { return true }
            return !workspace.isEmpty
        }
    }

    /// Keeps exactly one trailing empty workspace and drops the empty ones in between — niri's
    /// dynamic workspaces. A named workspace stays even when it is empty, also like niri: what
    /// removes it is the answer to `NiriWorkspaceRemoval`, not this.
    private func normalize(_ s: inout NiriStrip) {
        let focusedID = s.workspaces.indices.contains(s.focus) ? s.workspaces[s.focus].id : nil
        var kept = s.workspaces.filter { !$0.isEmpty || !$0.name.isEmpty }
        if let trailing = s.workspaces.last, trailing.isEmpty, trailing.name.isEmpty {
            kept.append(trailing) // reuse its identity so focus survives the prune
        } else {
            kept.append(NiriWorkspace())
        }
        for i in kept.indices {
            kept[i].focus = min(max(0, kept[i].focus), max(0, kept[i].columns.count - 1))
            kept[i].viewOffset = clampOffset(kept[i].viewOffset, in: kept[i])
        }
        if let focusedID, let index = kept.firstIndex(where: { $0.id == focusedID }) {
            s.focus = index
        } else {
            s.focus = min(max(0, s.focus), kept.count - 1)
        }
        s.workspaces = kept
    }

    // MARK: Geometry

    /// The overview is another way of looking at the same rail, so filling steps aside while it is
    /// open — with the gaps and the title bars back, the columns can be told apart — and comes back
    /// when it closes.
    var showsFill: NiriFill { isOverview ? .tiled : fill }
    /// One column, one screen: no gaps and no title bars.
    var fillsViewport: Bool { showsFill != .tiled }

    /// Scale of the whole canvas: 1 normally, zoomed out in the overview.
    var overviewScale: CGFloat {
        guard isOverview else { return 1 }
        guard let workspace = focusedWorkspace, !workspace.isEmpty else { return Self.overviewBaseScale }
        let fitting = viewport.width / contentWidth(workspace)
        return min(Self.overviewBaseScale, max(Self.minimumOverviewScale, fitting))
    }

    /// Width of what the viewport actually shows, in content points. The overview scales the canvas
    /// down, so it shows proportionally more of the strip — and scrolls when even that isn't enough.
    var visibleWidth: CGFloat { viewport.width / overviewScale }

    /// Where the focused column is on screen right now, in the strip's own coordinates. The mouse
    /// controls that belong to the focused window — the two step arrows — are placed against it
    /// rather than against the window, so they stand in the gap the layout already leaves instead of
    /// over the neighbour peeking in at the edge.
    var focusedColumnFrame: CGRect? {
        guard !isOverview, let workspace = focusedWorkspace, workspace.columns.indices.contains(workspace.focus) else { return nil }
        let frames = columnFrames(workspace)
        guard frames.indices.contains(workspace.focus) else { return nil }
        var frame = frames[workspace.focus]
        frame.origin.x -= resolvedOffset(workspace) - horizontalPreview
        return frame
    }

    /// Space between two columns, and between a column and the edge of the screen. Full width has none:
    /// the page runs to every edge, and the next window starts exactly one screen away.
    var gap: CGFloat { fillsViewport ? 0 : max(Self.minimumGap, (viewport.width * Self.gapFraction).rounded()) }
    var outerGap: CGFloat { gap }

    var columnHeight: CGFloat { max(200, viewport.height - 2 * outerGap) }

    /// One window, one screen. Every column in the rail is this wide — the viewport with the outer
    /// gaps taken off it — and filling takes the gaps too, so the difference between the two ways of
    /// showing a window is a gap and a corner radius, never a fraction of the page.
    var columnWidth: CGFloat {
        guard !fillsViewport else { return viewport.width }
        return max(280, viewport.width - 2 * outerGap)
    }

    /// The windows the strip is actually showing: the focused workspace's columns that fall inside the
    /// viewport, plus half a screen of margin on each side so stepping to a neighbour has its page
    /// ready. This is what gets a real web view and what the live-page budget pins — everything else
    /// in the strip is a card (see `LivePageCache`).
    ///
    /// Workspaces above and below are deliberately not in here, mid-gesture included: building a web
    /// view costs a hitch you can see, and doing it for a whole workspace while a scroll is still
    /// deciding where to land is the worst possible moment for it. What they already have stays.
    var visibleTabIDs: Set<UUID> {
        guard let workspace = focusedWorkspace, !workspace.isEmpty else { return [] }
        let frames = columnFrames(workspace)
        let scroll = resolvedOffset(workspace) - horizontalPreview
        let margin = visibleWidth / 2
        var ids: Set<UUID> = []
        for (index, column) in workspace.columns.enumerated() where frames.indices.contains(index) {
            let x = frames[index].minX - scroll
            if x + frames[index].width > -margin, x < visibleWidth + margin { ids.formUnion(column.tabIDs) }
        }
        return ids
    }

    /// Column rectangles in content space (x grows along the strip, origin at the strip's left edge).
    func columnFrames(_ workspace: NiriWorkspace) -> [CGRect] {
        columnFrames(workspace.columns)
    }

    /// The same, for a row that is not (yet) a workspace's own: what the overview draws while a window
    /// is being carried is the columns rearranged around the gap, and they are laid out the same way.
    func columnFrames(_ columns: [NiriColumn]) -> [CGRect] {
        var frames: [CGRect] = []
        var x = outerGap
        for _ in columns {
            frames.append(CGRect(x: x, y: outerGap, width: columnWidth, height: columnHeight))
            x += columnWidth + gap
        }
        return frames
    }

    /// The gap between the two halves of a split column, and deliberately not the same one as
    /// between columns: at the rail's own gap a split would be indistinguishable from two windows
    /// standing next to each other. Half of it, so proximity says what no chrome has to — these two
    /// are closer to each other than to anything else on the rail — with a floor, because at full
    /// width the rail's gap is zero and two pages flush against each other have no seam at all.
    var paneGap: CGFloat { max(4, (gap / 2).rounded()) }

    /// Every window of a row and where it stands — the columns' frames with each split column's own
    /// halves worked out. What the strip draws from; see `NiriWindowPlace`.
    func placements(_ columns: [NiriColumn]) -> [NiriWindowPlace] {
        let frames = columnFrames(columns)
        var places: [NiriWindowPlace] = []
        for (index, column) in columns.enumerated() where frames.indices.contains(index) {
            let panes = paneFrames(column, in: frames[index])
            for (pane, tabID) in column.tabIDs.enumerated() where panes.indices.contains(pane) {
                places.append(NiriWindowPlace(
                    tabID: tabID, frame: panes[pane],
                    side: column.isSplit ? (pane == 0 ? .left : .right) : .whole))
            }
        }
        return places
    }

    /// Where the windows of one column stand inside its frame: the whole of it, or two halves with
    /// `paneGap` between them.
    func paneFrames(_ column: NiriColumn, in frame: CGRect) -> [CGRect] {
        guard column.isSplit else { return [frame] }
        let width = ((frame.width - paneGap) / 2).rounded(.down)
        return [
            CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
            CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        ]
    }

    func contentWidth(_ workspace: NiriWorkspace) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }
        let count = CGFloat(workspace.columns.count)
        return columnWidth * count + gap * (count - 1) + 2 * outerGap
    }

    /// Where a workspace's row sits on the canvas: the focused one is at zero, the others a screen
    /// (and a gap) above or below it. The canvas is what the overview scales as a whole, so this is in
    /// the same points the column frames are.
    func rowY(_ index: Int) -> CGFloat {
        CGFloat(index - focusedWorkspaceIndex) * (viewport.height + workspaceSpacing) + verticalPreview
    }

    /// A workspace row is drawn wider than the window and centred on it — the overview shows more of
    /// the strip than the window is wide — so a column at `x` in that row's content space lands here on
    /// the canvas, and back again.
    func canvasX(content x: CGFloat, workspace index: Int) -> CGFloat {
        guard workspaces.indices.contains(index) else { return x }
        return x - resolvedOffset(workspaces[index]) - (visibleWidth - viewport.width) / 2
    }

    func contentX(canvas x: CGFloat, workspace index: Int) -> CGFloat {
        guard workspaces.indices.contains(index) else { return x }
        return x + resolvedOffset(workspaces[index]) + (visibleWidth - viewport.width) / 2
    }

    private func centeredOffset(_ frame: CGRect) -> CGFloat {
        frame.midX - visibleWidth / 2
    }

    /// How far the strip may scroll. While centring, the ends are reached when the first/last window
    /// sits in the middle, so every window can get there — otherwise the strip stops at its edges.
    private func offsetBounds(in workspace: NiriWorkspace) -> ClosedRange<CGFloat> {
        let width = visibleWidth
        let frames = columnFrames(workspace)
        // The overview shows strips, not a focused window: it scrolls freely and centres what fits.
        if centersFocus, !isOverview, let first = frames.first, let last = frames.last {
            let lower = centeredOffset(first)
            return lower...max(lower, centeredOffset(last))
        }
        let total = contentWidth(workspace)
        guard total > width else {
            let centred = (total - width) / 2 // the whole strip fits: centre it
            return centred...centred
        }
        return 0...(total - width)
    }

    private func clampOffset(_ offset: CGFloat, in workspace: NiriWorkspace) -> CGFloat {
        let bounds = offsetBounds(in: workspace)
        return min(max(offset, bounds.lowerBound), bounds.upperBound)
    }

    /// Scroll position actually used for drawing.
    func resolvedOffset(_ workspace: NiriWorkspace) -> CGFloat {
        clampOffset(workspace.viewOffset, in: workspace)
    }

    /// Centres the focused column, or — with centring off — scrolls the least it can to reveal it.
    private func scrollFocusIntoView(_ workspace: inout NiriWorkspace) {
        let frames = columnFrames(workspace)
        guard frames.indices.contains(workspace.focus) else { return }
        let frame = frames[workspace.focus]
        if centersFocus {
            workspace.viewOffset = clampOffset(centeredOffset(frame), in: workspace)
            return
        }
        let total = contentWidth(workspace)
        guard total > visibleWidth else {
            workspace.viewOffset = (total - visibleWidth) / 2
            return
        }
        var offset = clampOffset(workspace.viewOffset, in: workspace)
        if frame.minX - outerGap < offset { offset = frame.minX - outerGap }
        if frame.maxX + outerGap > offset + visibleWidth { offset = frame.maxX + outerGap - visibleWidth }
        workspace.viewOffset = clampOffset(offset, in: workspace)
    }

    /// Puts every workspace of one strip back under its focused window.
    private func recenterStrip(_ profileID: UUID) {
        mutate(profile: profileID) { s in
            for i in s.workspaces.indices { scrollFocusIntoView(&s.workspaces[i]) }
        }
    }

    /// Every strip, not just the one on screen: the viewport, the centring switch and the fill all
    /// belong to the window, so a strip left alone would still be scrolled for the geometry it last saw.
    func recenterStrips() {
        for profileID in Array(strips.keys) { recenterStrip(profileID) }
        recenterStrip(activeProfileID)
    }

    func setCentersFocus(_ value: Bool) {
        centersFocus = value
        recenterStrips()
    }

    /// Every column changes width here, so every offset that pointed at one has to be found again.
    func setFill(_ value: NiriFill) {
        guard value != fill else { return }
        fill = value
        recenterStrips()
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != viewport else { return }
        viewport = size
        recenterStrips()
    }

    // MARK: Columns

    /// Opens a tab as a new column to the right of the focused one, niri-style.
    /// A glance to the right: the strip leans that way far enough to show the edge of what just
    /// arrived, and comes back.
    ///
    /// This is what a ⌘-click has instead of a notification. The window it opens goes *behind* — the
    /// strip grows to the right and the focus deliberately stays on the page being read — which is
    /// correct and completely invisible, because the new column is usually past the edge of the
    /// screen. Leaning over shows the thing itself rather than a symbol standing in for it, and it
    /// costs nothing new: `horizontalPreview` is the rubber band a scroll gesture already borrows.
    ///
    /// A second ⌘-click restarts it rather than queueing: the strip stays leaned while they keep
    /// coming and settles once, at the end.
    var peekAmount: CGFloat { max(Self.minimumPeek, viewport.width * Self.peekFraction) }

    func peek(_ amount: CGFloat? = nil) {
        let amount = amount ?? peekAmount
        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Negative, because the columns are drawn at `frame.minX - (offset - horizontalPreview)`:
            // leaning right means scrolling further along the strip.
            withAnimation(.smooth(duration: 0.22)) { self.horizontalPreview = -amount }
            NiriLayout.trace("peek out \(horizontalPreview)")
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return } // a newer peek owns the band now, and will let go
            withAnimation(NiriLayout.switchAnimation) { self.horizontalPreview = 0 }
            NiriLayout.trace("peek back \(horizontalPreview)")
        }
    }

    // MARK: The end of the rail

    /// The rail was asked to go where there is nothing, and the light along that edge is the whole
    /// answer.
    ///
    /// A rail that simply refuses looks like a rail that did not hear: the strip does not move, the
    /// key gives nothing back, and the honest reading is that the gesture was lost. Everything else
    /// six does at an edge — the lean towards a window opening behind, the lean towards a hovered `+`
    /// — says *there is something over there* by leaning that way. This is the other half of the
    /// sentence, said the same way round: the edge you pushed into lights up, briefly, and nothing
    /// moves, because nothing is there to move to.
    ///
    /// Deliberately not a sound and not a bounce. A bounce is the rail moving, and the one thing that
    /// must stay true is that it did not.
    func hitWall(_ edge: NiriEdge) {
        wallTask?.cancel()
        wall = edge
        withAnimation(.smooth(duration: 0.12)) { wallGlow = 1 }
        NiriLayout.trace("wall \(edge)")
        wallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth(duration: 0.5)) { self.wallGlow = 0 }
        }
    }

    /// A gesture leaning on an edge with nothing behind it: the light follows the finger and lets go
    /// with it, so pushing gently at the end of the rail says the same thing quietly. `nil` is the
    /// gesture ending — or arriving somewhere there is a window after all.
    func pushWall(_ edge: NiriEdge?, by amount: CGFloat) {
        wallTask?.cancel()
        wallTask = nil
        guard let edge else {
            guard wallGlow != 0 else { return }
            withAnimation(NiriLayout.switchAnimation) { wallGlow = 0 }
            return
        }
        wall = edge
        // Un-animated on purpose: it is the finger's own position, and easing towards it would leave
        // the light still rising after the hand has stopped.
        wallGlow = min(1, abs(amount) / Self.wallPush)
    }

    /// Is there a window that way, or is that side a wall? The rubber band and the light both need
    /// the same answer, and an empty row is a wall on both sides.
    private func wallEdge(column delta: Int) -> NiriEdge? {
        guard !canFocusColumn(delta) else { return nil }
        return delta > 0 ? .trailing : .leading
    }

    private func wallEdge(workspace delta: Int) -> NiriEdge? {
        guard !canFocusWorkspace(delta) else { return nil }
        return delta > 0 ? .below : .above
    }

    /// The rubber band a horizontal gesture holds below the threshold, and what it means at the ends
    /// of the rail. The view hands over the raw band and gets both: a band that gives less where
    /// there is nothing behind it, and the light that says why.
    ///
    /// Sense as everywhere else here — the columns are drawn at `frame.minX - (offset - band)` — so a
    /// negative band is the rail leaning towards its far end.
    func previewColumn(_ amount: CGFloat) {
        guard amount != 0 else {
            pushWall(nil, by: 0)
            withAnimation(NiriLayout.switchAnimation) { horizontalPreview = 0 }
            return
        }
        let edge = wallEdge(column: amount < 0 ? 1 : -1)
        pushWall(edge, by: amount)
        horizontalPreview = edge == nil ? amount : amount * Self.wallResistance
    }

    /// The same for the vertical stack: one workspace per gesture, and a wall above the first row and
    /// below the last.
    func previewWorkspace(_ amount: CGFloat) {
        guard amount != 0 else {
            pushWall(nil, by: 0)
            withAnimation(NiriLayout.switchAnimation) { verticalPreview = 0 }
            return
        }
        let edge = wallEdge(workspace: amount < 0 ? 1 : -1)
        pushWall(edge, by: amount)
        verticalPreview = edge == nil ? amount : amount * Self.wallResistance
    }

    // MARK: Looking ahead at what is off the edge

    /// How far the strip leans while an edge button is under the pointer: exactly as far as it leans
    /// to show a window that opened behind (`peek`), and never further than the window it is revealing
    /// is wide. One distance for all of them, because they are the same sentence — *there is something
    /// over here* — and a strip that says it three times at three volumes is a strip saying it badly.
    ///
    /// Same sense as `horizontalPreview` — the columns are drawn at `frame.minX - (offset - lean)`, so
    /// leaning towards the far end of the strip is a negative number.
    var edgeLean: CGFloat {
        guard edgeHover != 0, !isOverview else { return 0 }
        // Something has to be over there to be worth showing: the next window, or the room a new one
        // would take. On an empty workspace there is neither, and the strip stays where it is.
        guard canFocusColumn(edgeHover) || newColumnFrame != nil else { return 0 }
        let amount = min(columnWidth + gap, peekAmount)
        return edgeHover > 0 ? -amount : amount
    }

    /// Where the window that `+` would open is going to stand, in content space, or `nil` when the
    /// hovered button is not a `+` at all. The `+` only appears at the end of the strip it points at —
    /// where there is no window to walk to — so the outline goes beyond the last column or before the
    /// first one.
    var newColumnFrame: CGRect? {
        guard edgeHover != 0, !canFocusColumn(edgeHover), !isOverview else { return nil }
        guard let workspace = focusedWorkspace, !workspace.isEmpty else { return nil }
        let frames = columnFrames(workspace.columns)
        let width = columnWidth
        let x: CGFloat
        if edgeHover > 0 {
            x = (frames.last?.maxX ?? outerGap) + gap
        } else {
            x = (frames.first?.minX ?? outerGap) - gap - width
        }
        return CGRect(x: x, y: outerGap, width: width, height: columnHeight)
    }

    /// Sets or clears the peek. A button only ever lets go of the side it took, so the pointer moving
    /// straight from one end of the strip to the other cannot leave it leaning the wrong way.
    func hoverStripEdge(_ direction: Int, _ hovering: Bool) {
        if hovering {
            edgeHover = direction
        } else if edgeHover == direction {
            edgeHover = 0
        }
    }

    // MARK: Columns

    func insertColumn(tabID: UUID, on side: NiriPlacement = .right) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let index = insertionIndex(in: ws, on: side)
            ws.columns.insert(NiriColumn(tabID: tabID), at: min(index, ws.columns.count))
            ws.focus = min(index, ws.columns.count - 1)
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    /// Where a new window goes in a row: after the focused column, or — for the `+` at the near end —
    /// before it. An empty row has only one place either way.
    private func insertionIndex(in workspace: NiriWorkspace, on side: NiriPlacement) -> Int {
        guard !workspace.columns.isEmpty else { return 0 }
        return side == .right ? workspace.focus + 1 : workspace.focus
    }

    /// Opens a tab in a given workspace of a given profile's strip — what an agent asks for through MCP.
    /// `workspace` defaults to the strip's focused one; with `focus` off the window is added right of
    /// the focused column but nothing on screen moves.
    func insertColumn(tabID: UUID, in profileID: UUID, workspace: Int? = nil, focus: Bool = true,
                      on side: NiriPlacement = .right) {
        mutate(profile: profileID) { s in
            let target = min(max(0, workspace ?? s.focus), s.workspaces.count - 1)
            guard s.workspaces.indices.contains(target) else { return }
            var ws = s.workspaces[target]
            let index = insertionIndex(in: ws, on: side)
            ws.columns.insert(NiriColumn(tabID: tabID), at: min(index, ws.columns.count))
            if focus {
                ws.focus = min(index, ws.columns.count - 1)
                scrollFocusIntoView(&ws)
                s.focus = target
            }
            s.workspaces[target] = ws
        }
    }

    /// Where a window stands in a profile's strip: which row, and how far along it. Read before the
    /// column goes, so a window that comes back can come back where it was.
    func location(ofTabID tabID: UUID, in profileID: UUID) -> (workspace: Int, index: Int)? {
        for (w, workspace) in strip(for: profileID).workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    /// Puts a column back where one was taken from — reopening a closed window. The row it left is not
    /// the row it returns to: windows have opened and closed since, so the place is a preference and
    /// not a promise, and both numbers land wherever the row can still take them.
    func restoreColumn(tabID: UUID, in profileID: UUID, workspace: Int, at index: Int) {
        mutate(profile: profileID) { s in
            guard !s.workspaces.isEmpty else { return }
            let target = min(max(0, workspace), s.workspaces.count - 1)
            var ws = s.workspaces[target]
            let at = min(max(0, index), ws.columns.count)
            ws.columns.insert(NiriColumn(tabID: tabID), at: at)
            ws.focus = at
            scrollFocusIntoView(&ws)
            s.focus = target
            s.workspaces[target] = ws
        }
    }

    /// Index of the workspace with this name in a profile's strip, creating it (as the trailing
    /// empty workspace, which gets the name and so survives being empty) when there is none.
    func workspaceIndex(named name: String, in profileID: UUID, createIfMissing: Bool) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let existing = strip(for: profileID).workspaces
        if let index = existing.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return index
        }
        guard createIfMissing else { return nil }
        var created: Int?
        mutate(profile: profileID) { s in
            if s.workspaces.last?.isEmpty == true, s.workspaces.last?.name.isEmpty == true {
                s.workspaces[s.workspaces.count - 1].name = wanted
            } else {
                s.workspaces.append(NiriWorkspace(name: wanted))
            }
            created = s.workspaces.count - 1
        }
        return created
    }

    /// Moves a column (wherever it is in the profile's strip) to a workspace by index, without changing focus.
    ///
    /// Un-animated for the reason `unanimated` gives: this is the same window changing rows, and an
    /// agent's `move_window` must not be able to trap WebKit either.
    func moveColumn(tabID: UUID, in profileID: UUID, toWorkspace target: Int) {
        unanimated {
            mutate(profile: profileID) { s in
                guard let from = s.workspaces.firstIndex(where: { $0.columns.contains { $0.holds(tabID) } }),
                      let at = s.workspaces[from].columns.firstIndex(where: { $0.holds(tabID) }) else { return }
                let target = max(0, target)
                guard target != from else { return }
                // The window and not the column it may be sharing: half a split moved to another row
                // leaves the other half where it stood, filling the column on its own.
                var column = s.workspaces[from].columns[at]
                if column.remove(tabID) {
                    s.workspaces[from].columns[at] = column
                    column = NiriColumn(tabID: tabID)
                } else {
                    s.workspaces[from].columns.remove(at: at)
                }
                s.workspaces[from].focus = min(s.workspaces[from].focus, max(0, s.workspaces[from].columns.count - 1))
                scrollFocusIntoView(&s.workspaces[from])
                askBeforeRemoving(s.workspaces[from], in: profileID)
                while target >= s.workspaces.count { s.workspaces.append(NiriWorkspace()) }
                var destination = s.workspaces[target]
                let index = destination.columns.isEmpty ? 0 : destination.focus + 1
                destination.columns.insert(column, at: min(index, destination.columns.count))
                s.workspaces[target] = destination
            }
        }
    }

    func removeColumn(tabID: UUID) {
        mutate { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                // Half a split closing leaves the other half where it stood, with the whole column to
                // itself — closing one of two windows is not closing the pair.
                if s.workspaces[i].columns[index].remove(tabID) {
                    s.workspaces[i].focus = index
                } else {
                    s.workspaces[i].columns.remove(at: index)
                    s.workspaces[i].focus = max(0, min(index, s.workspaces[i].columns.count - 1))
                }
                scrollFocusIntoView(&s.workspaces[i])
                askBeforeRemoving(s.workspaces[i], in: activeProfileID)
                return
            }
        }
    }

    /// Takes a column out of a strip that is not necessarily the one on screen, and — unlike closing
    /// a window — without asking about the row it empties.
    ///
    /// Both differences come from the one caller: a window moved to another profile
    /// (`BrowserState.moveTab(_:toProfile:)`). The column has to leave a strip nobody is looking at,
    /// or the rail it left goes on drawing a window that now stands somewhere else. And the question
    /// a named row asks when it loses its last window would arrive over the profile the window went
    /// *to*, about a row on the one it left, saying the window had been closed — which it was not.
    /// The row keeps its name and stands empty, which is what answering "Keep It" would have done,
    /// and its own menu still offers to delete it.
    func removeColumn(tabID: UUID, from profileID: UUID) {
        mutate(profile: profileID) { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                if s.workspaces[i].columns[index].remove(tabID) {
                    s.workspaces[i].focus = index
                } else {
                    s.workspaces[i].columns.remove(at: index)
                    s.workspaces[i].focus = max(0, min(index, s.workspaces[i].columns.count - 1))
                }
                scrollFocusIntoView(&s.workspaces[i])
                return
            }
        }
    }

    func focus(tabID: UUID) {
        mutate { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                s.focus = i
                s.workspaces[i].focus = index
                s.workspaces[i].columns[index].pane = s.workspaces[i].columns[index].paneIndex(of: tabID) ?? 0
                scrollFocusIntoView(&s.workspaces[i])
                return
            }
        }
    }

    func focusColumn(_ delta: Int) {
        // Asked for a window that is not there. The step is still clamped below — walking two columns
        // from the second-to-last one lands on the last, as it always did — but a step with nowhere at
        // all to go is answered by the edge it was aimed at rather than by silence.
        if let edge = wallEdge(column: delta > 0 ? 1 : -1), delta != 0 { hitWall(edge) }
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard !ws.columns.isEmpty, ws.columns.indices.contains(ws.focus) else { return }
            // Into the other half of a split first, the way a tiling WM steps through the windows of
            // a column before it steps to the next one: pressing ⌥→ twice from the left half of a
            // split lands on the window after the pair, and every window on the rail is one step
            // apart from its neighbour whether or not it is sharing a column.
            if abs(delta) == 1, ws.columns[ws.focus].isSplit,
               ws.columns[ws.focus].pane + delta == 0 || ws.columns[ws.focus].pane + delta == 1 {
                ws.columns[ws.focus].pane += delta
                s.workspaces[s.focus] = ws
                return
            }
            let target = min(max(0, ws.focus + delta), ws.columns.count - 1)
            guard target != ws.focus else { return }
            // Arriving from the right lands on the near half, so walking back along the rail walks
            // the windows in the order they are drawn in.
            ws.columns[target].pane = delta < 0 && ws.columns[target].isSplit ? 1 : 0
            ws.focus = target
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    func focusColumnEdge(last: Bool) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard !ws.columns.isEmpty else { return }
            ws.focus = last ? ws.columns.count - 1 : 0
            ws.columns[ws.focus].pane = last && ws.columns[ws.focus].isSplit ? 1 : 0
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    func moveColumn(_ delta: Int) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard ws.columns.indices.contains(ws.focus) else { return }
            // Inside a split the move swaps the two halves, which is the same rule the focus step
            // follows: ⌥⇧→ moves the window you are reading one place along, and inside a column
            // there is exactly one place to go.
            if abs(delta) == 1, ws.columns[ws.focus].isSplit,
               ws.columns[ws.focus].pane + delta == 0 || ws.columns[ws.focus].pane + delta == 1 {
                var column = ws.columns[ws.focus]
                let left = column.tabID
                column.tabID = column.second ?? left
                column.second = left
                column.pane += delta
                ws.columns[ws.focus] = column
                s.workspaces[s.focus] = ws
                return
            }
            let target = ws.focus + delta
            guard ws.columns.indices.contains(target) else { return }
            ws.columns.swapAt(ws.focus, target)
            ws.focus = target
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    // MARK: Splitting a column

    /// ⌥S: the window next along comes in beside the one you are reading, or the pair goes back to
    /// being two windows on the rail.
    ///
    /// Which window it takes is the one the rail would have walked to — the neighbour on the right,
    /// or the one on the left when the focused window is the last on the rail, so the end of a rail
    /// is not the one place a split cannot be made. It arrives on the side it came from, and the
    /// focus does not move: the window being read is the reason the key was pressed.
    ///
    /// Unsplitting is the same key and the plainer half: the window on the right steps out into a
    /// column of its own, immediately to the right, and the focus follows whichever of the two had
    /// it. Nothing is closed either way — a split is an arrangement of windows already on the rail.
    ///
    /// Returns whether anything happened, so a key pressed where there is nothing to split can say
    /// so with the wall rather than with silence.
    @discardableResult
    func toggleSplit() -> Bool {
        var changed = false
        // Animated, unlike every other change that moves a window from one column to another: the
        // strip draws by window and not by column (`NiriWindowPlace`), so nothing here is built or
        // torn down — the two halves slide into the width they now have, which is the whole of what
        // happened.
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard ws.columns.indices.contains(ws.focus) else { return }
            if ws.columns[ws.focus].isSplit {
                var column = ws.columns[ws.focus]
                guard let right = column.second else { return }
                let followed = column.focusedTabID
                column.remove(right)
                ws.columns[ws.focus] = column
                ws.columns.insert(NiriColumn(tabID: right), at: ws.focus + 1)
                if followed == right { ws.focus += 1 }
            } else {
                let side: NiriPlacement = ws.columns.indices.contains(ws.focus + 1) ? .right : .left
                let at = side == .right ? ws.focus + 1 : ws.focus - 1
                guard ws.columns.indices.contains(at) else { return }
                let home = ws.columns[ws.focus].id
                let taken = ws.columns[at].focusedTabID
                var neighbour = ws.columns[at]
                if neighbour.remove(taken) {
                    ws.columns[at] = neighbour
                } else {
                    ws.columns.remove(at: at)
                }
                // By id: taking the window from the left moves every index after it, this one
                // included.
                guard let index = ws.columns.firstIndex(where: { $0.id == home }) else { return }
                ws.columns[index].insert(taken, on: side)
                ws.focus = index
            }
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
            changed = true
        }
        if !changed { hitWall(.trailing) }
        return changed
    }

    /// Puts two named windows in one column, wherever the second one is standing now — what an
    /// agent asks for when it wants two pages side by side (`split_window` over MCP), and the one
    /// way in that does not go through "the window next along".
    ///
    /// The first window does not move: it keeps its column and its place on the rail, and the second
    /// arrives on its right. Refused where there is no room — the ceiling is two — and where either
    /// window is not in this strip.
    @discardableResult
    func split(tabID: UUID, with other: UUID, in profileID: UUID) -> Bool {
        guard tabID != other else { return false }
        var done = false
        mutate(profile: profileID) { s in
            guard let home = Self.place(of: tabID, in: s) else { return }
            if s.workspaces[home.workspace].columns[home.index].holds(other) { done = true; return }
            guard !s.workspaces[home.workspace].columns[home.index].isSplit else { return }
            guard let from = Self.place(of: other, in: s) else { return }
            let homeID = s.workspaces[home.workspace].columns[home.index].id
            var source = s.workspaces[from.workspace].columns[from.index]
            if source.remove(other) {
                s.workspaces[from.workspace].columns[from.index] = source
            } else {
                s.workspaces[from.workspace].columns.remove(at: from.index)
                s.workspaces[from.workspace].focus =
                    min(s.workspaces[from.workspace].focus, max(0, s.workspaces[from.workspace].columns.count - 1))
                askBeforeRemoving(s.workspaces[from.workspace], in: profileID)
            }
            // By id, because taking the window out has moved every index after it.
            guard let index = s.workspaces[home.workspace].columns.firstIndex(where: { $0.id == homeID }) else { return }
            s.workspaces[home.workspace].columns[index].insert(other, on: .right)
            s.workspaces[home.workspace].focus = index
            s.focus = home.workspace
            scrollFocusIntoView(&s.workspaces[home.workspace])
            done = true
        }
        return done
    }

    private static func place(of tabID: UUID, in strip: NiriStrip) -> (workspace: Int, index: Int)? {
        for (w, workspace) in strip.workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    /// Whether ⌥S has anything to do: a split to undo, or a window next along to take in.
    var canSplit: Bool {
        guard let ws = focusedWorkspace, ws.columns.indices.contains(ws.focus) else { return false }
        return ws.columns[ws.focus].isSplit || ws.columns.count > 1
    }

    var isSplit: Bool { focusedWorkspace?.focusedColumn?.isSplit ?? false }

    // MARK: Carrying a window across the overview

    /// Where a window is in the strip on screen.
    func location(of tabID: UUID) -> (workspace: Int, index: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    /// The columns a workspace draws right now: its own, unless a window is being carried, in which
    /// case the carried one is out of the row it came from and standing in the place it would land.
    /// The gap the overview opens up is that column's own frame, held by nothing — the card itself is
    /// drawn above the canvas, following the pointer (`carriedCardFrame`).
    func arrangement(workspaceAt index: Int) -> [NiriColumn] {
        guard workspaces.indices.contains(index) else { return [] }
        // Only while the overview is open. A drag that somehow outlived it would otherwise go on
        // rearranging the strip itself, which draws from here too.
        guard isOverview, let drag = columnDrag else { return workspaces[index].columns }
        var columns = rowUnderDrag(drag, workspace: index)
        guard index == drag.toWorkspace else { return columns }
        // Over the middle of another window: that column opens its other half, and the half stays
        // empty, because the window that would fill it is in the air. The gap held open where a
        // window would land is how every other part of this gesture answers, and this is that
        // sentence said inside a column.
        if let joins, let at = columns.firstIndex(where: { $0.id == joins }), !columns[at].isSplit {
            columns[at].insert(drag.tabID, on: drag.joinsSide)
        } else {
            columns.insert(NiriColumn(id: drag.placeholder, tabID: drag.tabID),
                           at: min(max(0, drag.toIndex), columns.count))
        }
        return columns
    }

    /// The row a drop would land in: the workspace's own columns, less the window in the air — which
    /// takes its column with it only if it had the column to itself.
    private func rowUnderDrag(_ drag: NiriColumnDrag, workspace index: Int) -> [NiriColumn] {
        var columns = workspaces[index].columns
        guard index == drag.fromWorkspace, let at = columns.firstIndex(where: { $0.holds(drag.tabID) })
        else { return columns }
        if !columns[at].remove(drag.tabID) { columns.remove(at: at) }
        return columns
    }

    /// The column the carried window would join, if it is over one.
    private var joins: UUID? { columnDrag?.joins }

    /// The frame the picked-up card had before it moved, in its own row's content space — the half
    /// of a split column, when that is what was picked up.
    private func liftedFrame(_ drag: NiriColumnDrag) -> CGRect? {
        guard workspaces.indices.contains(drag.fromWorkspace) else { return nil }
        let columns = workspaces[drag.fromWorkspace].columns
        let frames = columnFrames(columns)
        guard frames.indices.contains(drag.fromIndex), columns.indices.contains(drag.fromIndex) else { return nil }
        let panes = paneFrames(columns[drag.fromIndex], in: frames[drag.fromIndex])
        let pane = columns[drag.fromIndex].paneIndex(of: drag.tabID) ?? 0
        return panes.indices.contains(pane) ? panes[pane] : frames[drag.fromIndex]
    }

    /// Where the carried card is on the canvas: where it was lifted from, plus how far the pointer has
    /// gone since. The strip underneath does not move while it is in the air, so the card stays under
    /// the pointer exactly.
    var carriedCardFrame: CGRect? {
        guard isOverview, let drag = columnDrag, let frame = liftedFrame(drag) else { return nil }
        return CGRect(
            x: canvasX(content: frame.minX, workspace: drag.fromWorkspace) + drag.translation.width,
            y: rowY(drag.fromWorkspace) + frame.minY + drag.translation.height,
            width: frame.width,
            height: frame.height
        )
    }

    func beginColumnDrag(tabID: UUID) {
        guard isOverview, let at = location(of: tabID) else { return }
        let column = workspaces[at.workspace].columns[at.index]
        columnDrag = NiriColumnDrag(
            tabID: tabID, fromWorkspace: at.workspace, fromIndex: at.index,
            toWorkspace: at.workspace, toIndex: at.index,
            // A whole column moving keeps its identity all the way through, so the view that was
            // drawing it goes on drawing it; a half leaving a split is a column that does not exist
            // yet, and needs one that will not change under it at the drop (`NiriColumn.id`).
            placeholder: column.isSplit ? UUID() : column.id,
            fromColumn: column.id)
    }

    /// Where the window would land if it were let go now: the row whose middle its own middle is
    /// nearest, and the place along that row it has reached — counted the way a hand does, by how many
    /// windows it has gone past.
    func updateColumnDrag(translation: CGSize) {
        guard var drag = columnDrag, let frame = liftedFrame(drag) else { return }
        drag.translation = translation

        let step = viewport.height + workspaceSpacing
        let centreY = rowY(drag.fromWorkspace) + frame.midY + translation.height
        let rows = ((centreY - verticalPreview - viewport.height / 2) / step).rounded()
        drag.toWorkspace = min(max(0, focusedWorkspaceIndex + Int(rows)), workspaces.count - 1)

        let centreX = canvasX(content: frame.midX, workspace: drag.fromWorkspace) + translation.width
        let content = contentX(canvas: centreX, workspace: drag.toWorkspace)
        // Counted against the row as it *is*, not as it is being drawn: one window has gone past
        // another when their middles have crossed, and that is a fixed line. Measuring against the
        // shuffled row instead would move the line towards the card every time it moved — the window
        // to the right slides into the gap, and its middle arrives under the pointer at once.
        let row = workspaces[drag.toWorkspace].columns
        let frames = columnFrames(row)
        var index = 0
        var joins: UUID?
        var side: NiriPlacement = .right
        for (position, other) in frames.enumerated() where row.indices.contains(position) {
            let column = row[position]
            // The column the window is being carried out of, when it is going with it: it is not in
            // the row the drop lands in, so it is neither a place to count past nor one to join.
            let leaving = drag.toWorkspace == drag.fromWorkspace && column.holds(drag.tabID) && !column.isSplit
            if leaving { continue }
            if other.midX < content { index += 1 }
            // Let go over the *middle* of a window and the two join: by then the cards are all but
            // on top of each other, which is what a person means by putting one window on another,
            // and the space between the cards goes on meaning what it always did. Refused where
            // there is no room for a second half, and over the column it came from, which would be a
            // change wearing the look of one.
            guard !column.isSplit, !column.holds(drag.tabID) else { continue }
            if abs(content - other.midX) < other.width * Self.joinFraction {
                joins = column.id
                side = content < other.midX ? .left : .right
            }
        }
        drag.toIndex = index
        drag.joins = joins
        drag.joinsSide = side

        columnDrag = drag
    }

    /// How much of a window is its middle, for a drop that means *join this one* rather than *stand
    /// beside it*: the middle half of it. Wide enough to be easy to hit on purpose, and leaving a
    /// quarter of the card at each end where the answer is still the gap next to it.
    static let joinFraction: CGFloat = 0.25

    func cancelColumnDrag() {
        columnDrag = nil
    }

    /// Drops the carried window where the drag left it, and returns whether the strip changed.
    @discardableResult
    func commitColumnDrag() -> Bool {
        guard let drag = columnDrag else { return false }
        columnDrag = nil
        guard drag.movedSomewhere else { return false }
        var moved = false
        mutate { s in
            guard s.workspaces.indices.contains(drag.fromWorkspace),
                  let at = s.workspaces[drag.fromWorkspace].columns.firstIndex(where: { $0.holds(drag.tabID) })
            else { return }
            var column = s.workspaces[drag.fromWorkspace].columns[at]
            if column.remove(drag.tabID) {
                // Half a split was carried out: the other half stays where it stood, and what lands
                // is a column that has just come into being.
                s.workspaces[drag.fromWorkspace].columns[at] = column
                column = NiriColumn(id: drag.placeholder, tabID: drag.tabID)
            } else {
                s.workspaces[drag.fromWorkspace].columns.remove(at: at)
            }
            s.workspaces[drag.fromWorkspace].focus =
                min(s.workspaces[drag.fromWorkspace].focus, max(0, s.workspaces[drag.fromWorkspace].columns.count - 1))
            scrollFocusIntoView(&s.workspaces[drag.fromWorkspace])
            askBeforeRemoving(s.workspaces[drag.fromWorkspace], in: activeProfileID)

            let target = min(max(0, drag.toWorkspace), s.workspaces.count - 1)
            var destination = s.workspaces[target]
            var index = min(max(0, drag.toIndex), destination.columns.count)
            if let joins = drag.joins, let onto = destination.columns.firstIndex(where: { $0.id == joins }),
               !destination.columns[onto].isSplit {
                destination.columns[onto].insert(drag.tabID, on: drag.joinsSide)
                // The window that was let go is the window in front of you, which in a column of two
                // means the half it landed in and not the one that was already there.
                destination.columns[onto].pane = destination.columns[onto].paneIndex(of: drag.tabID) ?? 0
                index = onto
            } else {
                destination.columns.insert(column, at: index)
            }
            destination.focus = index
            scrollFocusIntoView(&destination)
            s.workspaces[target] = destination
            // The window is where the hand left it, so that is where the focus is — dropping a window
            // into another row and being left looking at the row it came from is the one thing this
            // gesture must not do.
            s.focus = target
            moved = true
        }
        return moved
    }

    // MARK: Strip scrolling

    /// Free horizontal panning of the strip (Mod + horizontal scroll), and of the strips in the
    /// overview. Refused while centring is on: there the strip only ever rests with the focused window
    /// in the middle.
    func panStrip(by delta: CGFloat) {
        guard !centersFocus || isOverview else { return }
        var refused: CGFloat = 0
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let wanted = ws.viewOffset + delta
            ws.viewOffset = clampOffset(wanted, in: ws)
            // How much of the push the rail could not take. A free pan has no rubber band to give —
            // the strip is under the fingers and stays where it is clamped — so what a wall has to
            // show is the light, and it brightens with the part of the gesture that went nowhere.
            refused = wanted - ws.viewOffset
            s.workspaces[s.focus] = ws
        }
        guard refused != 0 else { return pushWall(nil, by: 0) }
        pushWall(refused > 0 ? .trailing : .leading, by: refused)
    }

    /// After a pan, focus follows the view: the column nearest the middle of the screen wins.
    func snapFocusToView() {
        pushWall(nil, by: 0) // the fingers are off the rail, so the wall stops being pushed
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let frames = columnFrames(ws)
            guard !frames.isEmpty else { return }
            let centre = resolvedOffset(ws) + visibleWidth / 2
            let nearest = frames.enumerated().min { abs($0.element.midX - centre) < abs($1.element.midX - centre) }
            ws.focus = nearest?.offset ?? ws.focus
            scrollFocusIntoView(&ws) // the pan ends on a column, never between two
            s.workspaces[s.focus] = ws
        }
    }

    // MARK: Workspaces

    func focusWorkspace(_ delta: Int) {
        if let edge = wallEdge(workspace: delta > 0 ? 1 : -1), delta != 0 { hitWall(edge) }
        mutate { s in
            s.focus = min(max(0, s.focus + delta), s.workspaces.count - 1)
        }
    }

    func focusWorkspace(at index: Int) {
        mutate { s in
            s.focus = min(max(0, index), s.workspaces.count - 1)
        }
    }

    /// Moves the focused column to the workspace above/below and follows it.
    ///
    /// Two changes and not one, on purpose: the window changes rows without an animation of its own
    /// (`unanimated`, which is where the reason is written down), and the focus follows in a second
    /// one that keeps the switch animation — so the workspace still slides up or down under you,
    /// which is the movement this gesture is actually about.
    func moveColumnToWorkspace(_ delta: Int) {
        var landed: UUID?
        unanimated {
            mutate { s in
                guard s.workspaces.indices.contains(s.focus) else { return }
                var source = s.workspaces[s.focus]
                guard source.columns.indices.contains(source.focus) else { return }
                let target = s.focus + delta
                guard target >= 0 else { return }
                // What moves is the window in front of you. Half a split leaves the other half where
                // it stood — ⌥⇧↓ is "take this one down there", and taking its neighbour along
                // because they happened to be sharing a column is not what was asked.
                var column = source.columns[source.focus]
                let moved = column.focusedTabID
                if column.remove(moved) {
                    source.columns[source.focus] = column
                    column = NiriColumn(tabID: moved)
                } else {
                    source.columns.remove(at: source.focus)
                    source.focus = min(source.focus, max(0, source.columns.count - 1))
                }
                scrollFocusIntoView(&source)
                askBeforeRemoving(source, in: activeProfileID)
                s.workspaces[s.focus] = source

                if target >= s.workspaces.count { s.workspaces.append(NiriWorkspace()) }
                var destination = s.workspaces[target]
                let index = destination.columns.isEmpty ? 0 : destination.focus + 1
                destination.columns.insert(column, at: min(index, destination.columns.count))
                destination.focus = min(index, destination.columns.count - 1)
                scrollFocusIntoView(&destination)
                s.workspaces[target] = destination
                landed = destination.id
            }
        }
        // By id and not by index: `normalize` runs between the two, and the row the window left can
        // be pruned out from under an index that was true a moment ago.
        guard let landed else { return }
        mutate { s in
            guard let index = s.workspaces.firstIndex(where: { $0.id == landed }) else { return }
            s.focus = index
        }
    }

    /// The name, or the position when there is none.
    func title(at index: Int) -> String {
        guard workspaces.indices.contains(index), !workspaces[index].name.isEmpty else {
            #if os(Linux)
            return "Workspace \(index + 1)"
            #else
            return String(localized: "Workspace \(index + 1)")
            #endif
        }
        return workspaces[index].name
    }

    func rename(workspaceAt index: Int, to name: String) {
        mutate { s in
            guard s.workspaces.indices.contains(index) else { return }
            s.workspaces[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func removeProfile(_ id: UUID) {
        strips[id] = nil
        // Its windows were closed one by one on the way here, so its named rows have been queueing
        // up questions about a profile that is being deleted whole. Nobody wants to be asked eight
        // times whether to keep a workspace inside something they just threw away.
        pendingRemovals.removeAll { $0.profileID == id }
    }
}
