import Foundation
import Observation
import SwiftUI

// MARK: - Model

/// One window in the strip: a tab plus its niri-style sizing.
struct NiriColumn: Identifiable, Hashable, Sendable {
    var tabID: UUID
    var widthIndex: Int = NiriLayout.defaultWidthIndex
    var id: UUID { tabID }
}

/// A niri workspace: an infinite horizontal strip of full-height columns.
struct NiriWorkspace: Identifiable, Sendable {
    var id = UUID()
    var columns: [NiriColumn] = []
    /// Index of the focused column.
    var focus: Int = 0
    /// Scroll position of the strip, in points of content space.
    var viewOffset: CGFloat = 0

    var isEmpty: Bool { columns.isEmpty }
    var focusedColumn: NiriColumn? { columns.indices.contains(focus) ? columns[focus] : nil }
}

/// The vertical stack of workspaces belonging to one profile.
struct NiriStrip: Sendable {
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
    static let defaultWidthIndex = 2
    static let gap: CGFloat = 12
    static let outerGap: CGFloat = 12
    static let overviewScale: CGFloat = 0.5
    static let switchAnimation: Animation = .smooth(duration: 0.34, extraBounce: 0.05)

    var viewport: CGSize = CGSize(width: 1280, height: 800)
    var isOverview = false
    /// Rubber-band offset while a vertical scroll gesture is still below the switch threshold.
    var verticalPreview: CGFloat = 0
    var activeProfileID: UUID = UUID()

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
    var workspaceSpacing: CGFloat { isOverview ? 90 : 16 }

    private func mutate(_ body: (inout NiriStrip) -> Void) {
        var s = strips[activeProfileID] ?? NiriStrip()
        body(&s)
        normalize(&s)
        strips[activeProfileID] = s
    }

    /// Keeps exactly one trailing empty workspace and drops the empty ones in between — niri's
    /// dynamic workspaces.
    private func normalize(_ s: inout NiriStrip) {
        let focusedID = s.workspaces.indices.contains(s.focus) ? s.workspaces[s.focus].id : nil
        var kept = s.workspaces.filter { !$0.isEmpty }
        if let trailing = s.workspaces.last, trailing.isEmpty {
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

    /// Working area, with one gap folded in so N columns of 1/N exactly fill the screen.
    private var usableWidth: CGFloat { max(360, viewport.width - 2 * Self.outerGap + Self.gap) }

    var columnHeight: CGFloat { max(200, viewport.height - 2 * Self.outerGap) }

    func width(of column: NiriColumn) -> CGFloat {
        let fraction = Self.widthPresets[min(max(0, column.widthIndex), Self.widthPresets.count - 1)]
        return max(280, usableWidth * fraction - Self.gap)
    }

    /// Column rectangles in content space (x grows along the strip, origin at the strip's left edge).
    func columnFrames(_ workspace: NiriWorkspace) -> [CGRect] {
        var frames: [CGRect] = []
        var x = Self.outerGap
        for column in workspace.columns {
            let w = width(of: column)
            frames.append(CGRect(x: x, y: Self.outerGap, width: w, height: columnHeight))
            x += w + Self.gap
        }
        return frames
    }

    func contentWidth(_ workspace: NiriWorkspace) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }
        let widths = workspace.columns.reduce(CGFloat.zero) { $0 + width(of: $1) }
        return widths + Self.gap * CGFloat(workspace.columns.count - 1) + 2 * Self.outerGap
    }

    private func clampOffset(_ offset: CGFloat, in workspace: NiriWorkspace) -> CGFloat {
        let total = contentWidth(workspace)
        guard total > viewport.width else { return (total - viewport.width) / 2 } // centred when it fits
        return min(max(offset, 0), total - viewport.width)
    }

    /// Scroll position actually used for drawing.
    func resolvedOffset(_ workspace: NiriWorkspace) -> CGFloat {
        clampOffset(workspace.viewOffset, in: workspace)
    }

    /// Smallest scroll that brings the focused column fully on screen.
    private func scrollFocusIntoView(_ workspace: inout NiriWorkspace) {
        let frames = columnFrames(workspace)
        guard frames.indices.contains(workspace.focus) else { return }
        let total = contentWidth(workspace)
        guard total > viewport.width else {
            workspace.viewOffset = (total - viewport.width) / 2
            return
        }
        let frame = frames[workspace.focus]
        var offset = clampOffset(workspace.viewOffset, in: workspace)
        if frame.minX - Self.outerGap < offset { offset = frame.minX - Self.outerGap }
        if frame.maxX + Self.outerGap > offset + viewport.width { offset = frame.maxX + Self.outerGap - viewport.width }
        workspace.viewOffset = clampOffset(offset, in: workspace)
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != viewport else { return }
        viewport = size
        mutate { s in
            for i in s.workspaces.indices { scrollFocusIntoView(&s.workspaces[i]) }
        }
    }

    // MARK: Columns

    /// Opens a tab as a new column to the right of the focused one, niri-style.
    func insertColumn(tabID: UUID) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let index = ws.columns.isEmpty ? 0 : ws.focus + 1
            ws.columns.insert(NiriColumn(tabID: tabID), at: min(index, ws.columns.count))
            ws.focus = min(index, ws.columns.count - 1)
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
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

    /// niri's "switch preset column width".
    func cycleColumnWidth() {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard ws.columns.indices.contains(ws.focus) else { return }
            ws.columns[ws.focus].widthIndex = (ws.columns[ws.focus].widthIndex + 1) % Self.widthPresets.count
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    /// niri's "maximize column": full width, or back to the default.
    func toggleFullWidth() {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            guard ws.columns.indices.contains(ws.focus) else { return }
            let full = Self.widthPresets.count - 1
            ws.columns[ws.focus].widthIndex = ws.columns[ws.focus].widthIndex == full ? Self.defaultWidthIndex : full
            scrollFocusIntoView(&ws)
            s.workspaces[s.focus] = ws
        }
    }

    // MARK: Strip scrolling

    /// Free horizontal panning of the strip (Mod + horizontal scroll).
    func panStrip(by delta: CGFloat) {
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
            let centre = resolvedOffset(ws) + viewport.width / 2
            let nearest = frames.enumerated().min { abs($0.element.midX - centre) < abs($1.element.midX - centre) }
            ws.focus = nearest?.offset ?? ws.focus
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

    func removeProfile(_ id: UUID) {
        strips[id] = nil
    }
}
