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

/// One window in the strip: a tab plus its niri-style sizing.
nonisolated struct NiriColumn: Identifiable, Hashable, Sendable, Codable {
    var tabID: UUID
    var id: UUID { tabID }
}

/// A niri workspace: an infinite horizontal strip of full-height columns.
nonisolated struct NiriWorkspace: Identifiable, Sendable, Codable {
    var id = UUID()
    /// Optional, like niri's named workspaces. A named one survives running out of windows.
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
/// a screen's worth of page in all three: the strip leaves it the gaps it needs to read as a card in
/// a row of them, the other two take even those away. There is deliberately nothing smaller — a
/// browser window at two thirds of a screen is a page with a hole beside it, and choosing between
/// four fractions of one is a decision nobody asked for.
nonisolated enum NiriFill: String, Sendable, Codable {
    /// The strip as usual: the gaps, and a window as wide as the screen leaves room for.
    case tiled
    /// The page fills the window under the top bar — no gaps, no title bar. The layout's own controls
    /// stay where they are.
    case window
    /// Fullscreen: the top bar goes too, and only the bar hiding at the top edge comes back.
    case screen
}

/// Which side of the focused column a new window opens on. Right is niri's own answer and stays the
/// default; left is what the `+` at the near end of the strip asks for, where there is no window to
/// step to and the empty gap used to mean nothing at all.
nonisolated enum NiriPlacement: Sendable {
    case left
    case right
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
    /// Pointer travel since the card was picked up, in canvas points (the overview's scale is applied
    /// to the whole canvas afterwards, so these are the same units the column frames are in).
    var translation: CGSize = .zero

    var movedSomewhere: Bool { toWorkspace != fromWorkspace || toIndex != fromIndex }
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

    /// `SIX_UI_DEBUG=1`: what the layout was asked to do, and what it thought it was doing. A gesture
    /// that does nothing is either not arriving or not meaning what it looks like, and this says which.
    static let tracesUI = ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard tracesUI else { return }
        FileHandle.standardError.write(Data("[six] ui: \(message())\n".utf8))
    }

    var viewport: CGSize = CGSize(width: 1280, height: 800)
    var isOverview = false
    /// niri's fullscreen, as a mode rather than per-window state — and one step short of it, filling the
    /// window instead of the screen. Either way the strip goes on working underneath, so ⌥←/⌥→ walks
    /// from one full window to the next. Neither is macOS fullscreen (the green button), and neither is
    /// a page asking for `requestFullscreen`, which WebKit handles on its own inside the web view.
    private(set) var fill: NiriFill = .tiled
    /// niri's `center-focused-column`: park the focused window in the middle of the screen instead of
    /// scrolling as little as possible. Off means the strip only moves when the focus would fall off it.
    /// Set from settings by `BrowserState`, which also writes the toggle back.
    var centersFocus = true
    /// Rubber-band offsets while a scroll gesture is still below the switch threshold.
    var verticalPreview: CGFloat = 0
    var horizontalPreview: CGFloat = 0
    /// The pointer resting on a `+`: -1 for the one at the near end of the strip, 1 for the far end,
    /// 0 for neither. The strip leans that way while it is held, and an outline of the window the
    /// button would open stands in the gap it opens up — the button shows what it does before it does
    /// it. Deliberately not `horizontalPreview`: that band belongs to the scroll gesture, and a peek
    /// held by the mouse has to survive one arriving.
    var newColumnHover = 0
    /// A window being carried across the overview, or `nil`. See `NiriColumnDrag`.
    var columnDrag: NiriColumnDrag?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
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
    var focusedTabID: UUID? { focusedWorkspace?.focusedColumn?.tabID }
    var hasColumns: Bool { strip.workspaces.contains { !$0.isEmpty } }

    /// Is there a column that way? Drives the on-screen edge buttons.
    func canFocusColumn(_ delta: Int) -> Bool {
        guard let ws = focusedWorkspace else { return false }
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

    private func mutate(profile: UUID, _ body: (inout NiriStrip) -> Void) {
        var s = strips[profile] ?? NiriStrip()
        body(&s)
        normalize(&s)
        strips[profile] = s
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

    /// Keeps exactly one trailing empty workspace and drops the empty ones in between — niri's
    /// dynamic workspaces. A named workspace stays even when it is empty, also like niri.
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

    /// The overview is another way of looking at the same strip, so filling steps aside while it is
    /// open — with the gaps and the title bars back, the columns can be told apart — and comes back
    /// when it closes.
    var showsFill: NiriFill { isOverview ? .tiled : fill }
    /// One column, one screen: no gaps and no title bars, in both filling modes.
    var fillsViewport: Bool { showsFill != .tiled }
    /// Only fullscreen takes the top bar with it.
    var showsFullscreen: Bool { showsFill == .screen }

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

    /// Space between two columns, and between a column and the edge of the screen. Fullscreen has none:
    /// the page runs to every edge, and the next window starts exactly one screen away.
    var gap: CGFloat { fillsViewport ? 0 : max(Self.minimumGap, (viewport.width * Self.gapFraction).rounded()) }
    var outerGap: CGFloat { gap }

    var columnHeight: CGFloat { max(200, viewport.height - 2 * outerGap) }

    /// One window, one screen. Every column in the strip is this wide — the viewport with the outer
    /// gaps taken off it — and filling takes the gaps too, so the difference between the three ways
    /// of showing a window is a gap and a corner radius, never a fraction of the page.
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
            if x + frames[index].width > -margin, x < visibleWidth + margin { ids.insert(column.tabID) }
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

    /// Every strip, not just the one on screen: the viewport, the centring switch and fullscreen all
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
            withAnimation(.smooth(duration: 0.22)) { horizontalPreview = -amount }
            NiriLayout.trace("peek out \(horizontalPreview)")
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return } // a newer peek owns the band now, and will let go
            withAnimation(NiriLayout.switchAnimation) { horizontalPreview = 0 }
            NiriLayout.trace("peek back \(horizontalPreview)")
        }
    }

    // MARK: Looking ahead at a window that isn't there yet

    /// How far the strip leans while a `+` is under the pointer: exactly as far as it leans to show a
    /// window that opened behind (`peek`), and never further than the window it is revealing is wide.
    /// One distance for both, because they are the same sentence — *there is something over here* —
    /// and a strip that says it twice at two different volumes is a strip saying it badly.
    ///
    /// Same sense as `horizontalPreview` — the columns are drawn at `frame.minX - (offset - lean)`, so
    /// leaning towards the far end of the strip is a negative number.
    var newColumnLean: CGFloat {
        guard newColumnHover != 0, newColumnFrame != nil else { return 0 }
        let amount = min(columnWidth + gap, peekAmount)
        return newColumnHover > 0 ? -amount : amount
    }

    /// Where the window that `+` would open is going to stand, in content space, or `nil` when no `+`
    /// is being hovered. The button only ever appears at the end of the strip it points at, so the
    /// outline goes beyond the last column or before the first one.
    var newColumnFrame: CGRect? {
        guard newColumnHover != 0, !isOverview, let workspace = focusedWorkspace, !workspace.isEmpty else { return nil }
        let frames = columnFrames(workspace.columns)
        let width = columnWidth
        let x: CGFloat
        if newColumnHover > 0 {
            x = (frames.last?.maxX ?? outerGap) + gap
        } else {
            x = (frames.first?.minX ?? outerGap) - gap - width
        }
        return CGRect(x: x, y: outerGap, width: width, height: columnHeight)
    }

    /// Sets or clears the peek. A button only ever lets go of the side it took, so the pointer moving
    /// straight from one end of the strip to the other cannot leave it leaning the wrong way.
    func hoverNewColumn(_ direction: Int, _ hovering: Bool) {
        if hovering {
            newColumnHover = direction
        } else if newColumnHover == direction {
            newColumnHover = 0
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
    func moveColumn(tabID: UUID, in profileID: UUID, toWorkspace target: Int) {
        mutate(profile: profileID) { s in
            guard let from = s.workspaces.firstIndex(where: { $0.columns.contains { $0.tabID == tabID } }),
                  let at = s.workspaces[from].columns.firstIndex(where: { $0.tabID == tabID }) else { return }
            let target = max(0, target)
            guard target != from else { return }
            let column = s.workspaces[from].columns.remove(at: at)
            s.workspaces[from].focus = min(s.workspaces[from].focus, max(0, s.workspaces[from].columns.count - 1))
            scrollFocusIntoView(&s.workspaces[from])
            while target >= s.workspaces.count { s.workspaces.append(NiriWorkspace()) }
            var destination = s.workspaces[target]
            let index = destination.columns.isEmpty ? 0 : destination.focus + 1
            destination.columns.insert(column, at: min(index, destination.columns.count))
            s.workspaces[target] = destination
        }
    }

    func removeColumn(tabID: UUID) {
        mutate { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.tabID == tabID }) else { continue }
                s.workspaces[i].columns.remove(at: index)
                s.workspaces[i].focus = max(0, min(index, s.workspaces[i].columns.count - 1))
                scrollFocusIntoView(&s.workspaces[i])
                return
            }
        }
    }

    func focus(tabID: UUID) {
        mutate { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.tabID == tabID }) else { continue }
                s.focus = i
                s.workspaces[i].focus = index
                scrollFocusIntoView(&s.workspaces[i])
                return
            }
        }
    }

    func focusColumn(_ delta: Int) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard !ws.columns.isEmpty else { return }
            ws.focus = min(max(0, ws.focus + delta), ws.columns.count - 1)
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
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    func moveColumn(_ delta: Int) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let target = ws.focus + delta
            guard ws.columns.indices.contains(ws.focus), ws.columns.indices.contains(target) else { return }
            ws.columns.swapAt(ws.focus, target)
            ws.focus = target
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    // MARK: Carrying a window across the overview

    /// Where a window is in the strip on screen.
    func location(of tabID: UUID) -> (workspace: Int, index: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.tabID == tabID }) { return (w, index) }
        }
        return nil
    }

    private func column(_ tabID: UUID) -> NiriColumn? {
        strip.workspaces.lazy.flatMap(\.columns).first { $0.tabID == tabID }
    }

    /// The columns a workspace draws right now: its own, unless a window is being carried, in which
    /// case the carried one is out of the row it came from and standing in the place it would land.
    /// The gap the overview opens up is that column's own frame, held by nothing — the card itself is
    /// drawn above the canvas, following the pointer (`carriedCardFrame`).
    func arrangement(workspaceAt index: Int) -> [NiriColumn] {
        guard workspaces.indices.contains(index) else { return [] }
        var columns = workspaces[index].columns
        // Only while the overview is open. A drag that somehow outlived it would otherwise go on
        // rearranging the strip itself, which draws from here too.
        guard isOverview, let drag = columnDrag else { return columns }
        if index == drag.fromWorkspace, let at = columns.firstIndex(where: { $0.tabID == drag.tabID }) {
            columns.remove(at: at)
        }
        if index == drag.toWorkspace, let carried = column(drag.tabID) {
            columns.insert(carried, at: min(max(0, drag.toIndex), columns.count))
        }
        return columns
    }

    /// The frame the picked-up card had before it moved, in its own row's content space.
    private func liftedFrame(_ drag: NiriColumnDrag) -> CGRect? {
        guard workspaces.indices.contains(drag.fromWorkspace) else { return nil }
        let frames = columnFrames(workspaces[drag.fromWorkspace].columns)
        guard frames.indices.contains(drag.fromIndex) else { return nil }
        return frames[drag.fromIndex]
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
        columnDrag = NiriColumnDrag(tabID: tabID, fromWorkspace: at.workspace, fromIndex: at.index,
                                    toWorkspace: at.workspace, toIndex: at.index)
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
        let frames = columnFrames(workspaces[drag.toWorkspace].columns)
        var index = 0
        for (position, other) in frames.enumerated() {
            if drag.toWorkspace == drag.fromWorkspace, position == drag.fromIndex { continue }
            if other.midX < content { index += 1 }
        }
        drag.toIndex = index

        columnDrag = drag
    }

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
                  let at = s.workspaces[drag.fromWorkspace].columns.firstIndex(where: { $0.tabID == drag.tabID })
            else { return }
            let column = s.workspaces[drag.fromWorkspace].columns.remove(at: at)
            s.workspaces[drag.fromWorkspace].focus =
                min(s.workspaces[drag.fromWorkspace].focus, max(0, s.workspaces[drag.fromWorkspace].columns.count - 1))
            scrollFocusIntoView(&s.workspaces[drag.fromWorkspace])

            let target = min(max(0, drag.toWorkspace), s.workspaces.count - 1)
            var destination = s.workspaces[target]
            let index = min(max(0, drag.toIndex), destination.columns.count)
            destination.columns.insert(column, at: index)
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
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            ws.viewOffset = clampOffset(ws.viewOffset + delta, in: ws)
            s.workspaces[s.focus] = ws
        }
    }

    /// After a pan, focus follows the view: the column nearest the middle of the screen wins.
    func snapFocusToView() {
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
    func moveColumnToWorkspace(_ delta: Int) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var source = s.workspaces[s.focus]
            guard source.columns.indices.contains(source.focus) else { return }
            let target = s.focus + delta
            guard target >= 0 else { return }
            let column = source.columns.remove(at: source.focus)
            source.focus = min(source.focus, max(0, source.columns.count - 1))
            scrollFocusIntoView(&source)
            s.workspaces[s.focus] = source

            if target >= s.workspaces.count { s.workspaces.append(NiriWorkspace()) }
            var destination = s.workspaces[target]
            let index = destination.columns.isEmpty ? 0 : destination.focus + 1
            destination.columns.insert(column, at: min(index, destination.columns.count))
            destination.focus = min(index, destination.columns.count - 1)
            scrollFocusIntoView(&destination)
            s.workspaces[target] = destination
            s.focus = target
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
    }
}
