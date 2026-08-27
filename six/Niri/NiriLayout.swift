import Foundation
import Observation
import SwiftUI

// MARK: - Model

/// One window in the strip: a tab plus its niri-style sizing.
nonisolated struct NiriColumn: Identifiable, Hashable, Sendable, Codable {
    var tabID: UUID
    var widthIndex: Int = NiriLayout.defaultWidthIndex
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

/// How much room the focused window is given. The widths in `widthPresets` are the tiled case; the
/// other two step outside the tiling entirely, and the strip goes on working underneath both.
nonisolated enum NiriFill: String, Sendable, Codable {
    /// The strip as usual: gaps, title bars, and the width the column's preset asks for.
    case tiled
    /// The page fills the window under the top bar — no gaps, no title bar. The layout's own controls
    /// stay where they are.
    case window
    /// Fullscreen: the top bar goes too, and only the bar hiding at the top edge comes back.
    case screen
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
    /// Column widths, as a fraction of the working area — same idea as niri's `preset-column-widths`.
    /// The default is "almost full": a normal browser window, with the next one peeking in at the edge.
    static let widthPresets: [CGFloat] = [0.5, 2.0 / 3.0, 0.88, 1.0]
    /// Menu names for the presets, in the same order.
    static let widthPresetTitles = ["Half", "Two Thirds", "Peek", "Full"]
    nonisolated static let defaultWidthIndex = 2
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
    /// The preset every window uses (⌥R cycles it for all of them at once); new windows open with
    /// it. Unlike niri this is one value for the whole app, not per column — a strip where each
    /// window has its own width reads as a mess. Compact width (⌥F) still widens one window against it.
    var preferredWidthIndex = NiriLayout.defaultWidthIndex
    /// Rubber-band offsets while a scroll gesture is still below the switch threshold.
    var verticalPreview: CGFloat = 0
    var horizontalPreview: CGFloat = 0
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

    /// Space between two columns, and between a column and the edge of the screen. Fullscreen has none:
    /// the page runs to every edge, and the next window starts exactly one screen away.
    var gap: CGFloat { fillsViewport ? 0 : max(Self.minimumGap, (viewport.width * Self.gapFraction).rounded()) }
    var outerGap: CGFloat { gap }

    /// Working area, with one gap folded in so N columns of 1/N exactly fill the screen.
    private var usableWidth: CGFloat { max(360, viewport.width - 2 * outerGap + gap) }

    var columnHeight: CGFloat { max(200, viewport.height - 2 * outerGap) }

    func width(of column: NiriColumn) -> CGFloat {
        // Filling overrides the preset without touching it: the widths are all still there on the way
        // out.
        guard !fillsViewport else { return viewport.width }
        let fraction = Self.widthPresets[min(max(0, column.widthIndex), Self.widthPresets.count - 1)]
        return max(280, usableWidth * fraction - gap)
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
        var frames: [CGRect] = []
        var x = outerGap
        for column in workspace.columns {
            let w = width(of: column)
            frames.append(CGRect(x: x, y: outerGap, width: w, height: columnHeight))
            x += w + gap
        }
        return frames
    }

    func contentWidth(_ workspace: NiriWorkspace) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }
        let widths = workspace.columns.reduce(CGFloat.zero) { $0 + width(of: $1) }
        return widths + gap * CGFloat(workspace.columns.count - 1) + 2 * outerGap
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
    func insertColumn(tabID: UUID) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let index = ws.columns.isEmpty ? 0 : ws.focus + 1
            ws.columns.insert(NiriColumn(tabID: tabID, widthIndex: preferredWidthIndex), at: min(index, ws.columns.count))
            ws.focus = min(index, ws.columns.count - 1)
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    /// Opens a tab in a given workspace of a given profile's strip — what an agent asks for through MCP.
    /// `workspace` defaults to the strip's focused one; with `focus` off the window is added right of
    /// the focused column but nothing on screen moves.
    func insertColumn(tabID: UUID, in profileID: UUID, workspace: Int? = nil, focus: Bool = true) {
        mutate(profile: profileID) { s in
            let target = min(max(0, workspace ?? s.focus), s.workspaces.count - 1)
            guard s.workspaces.indices.contains(target) else { return }
            var ws = s.workspaces[target]
            let index = ws.columns.isEmpty ? 0 : ws.focus + 1
            ws.columns.insert(NiriColumn(tabID: tabID, widthIndex: preferredWidthIndex), at: min(index, ws.columns.count))
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

    /// One preset wider or narrower, for every window in every strip. Stops at the ends — no
    /// wrapping around, so the key always does what its name says.
    func stepColumnWidth(_ delta: Int) {
        setPreferredWidth(preferredWidthIndex + delta)
    }

    /// Is this window at the widest preset (compact width)?
    func isFullWidth(tabID: UUID) -> Bool {
        strip.workspaces.lazy.flatMap(\.columns).first { $0.tabID == tabID }?.widthIndex == Self.widthPresets.count - 1
    }

    /// Is the focused window at the widest preset (compact width)?
    var focusedColumnIsFullWidth: Bool {
        focusedWorkspace?.focusedColumn?.widthIndex == Self.widthPresets.count - 1
    }

    /// Applies a preset to every window everywhere (a restored setting, or ⌥R).
    func setPreferredWidth(_ index: Int) {
        preferredWidthIndex = min(max(0, index), Self.widthPresets.count - 1)
        for profile in strips.keys {
            mutate(profile: profile) { s in
                for w in s.workspaces.indices {
                    for c in s.workspaces[w].columns.indices { s.workspaces[w].columns[c].widthIndex = preferredWidthIndex }
                    scrollFocusIntoView(&s.workspaces[w])
                }
            }
        }
    }

    /// niri's "maximize column": the widest preset, or back to the default. Still tiled — the gaps and
    /// the title bar stay, which is what makes it the compact one next to `NiriFill.window`.
    func toggleCompactWidth() {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard ws.columns.indices.contains(ws.focus) else { return }
            let full = Self.widthPresets.count - 1
            // Back to the shared preset — unless that is the full width itself, then to the default,
            // so the toggle always has somewhere to go.
            let narrow = preferredWidthIndex == full ? Self.defaultWidthIndex : preferredWidthIndex
            ws.columns[ws.focus].widthIndex = ws.columns[ws.focus].widthIndex == full ? narrow : full
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
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
            return "Workspace \(index + 1)"
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
