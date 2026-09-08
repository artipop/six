import Foundation
@testable internal import SixCoreShared

/// The rail's own state: `NiriLayout` plus what a column needs to draw itself and, once it is
/// live, to load.
///
/// No database — see `docs/windows.md` for what that leaves out and why. The rail and its
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

    /// Every front's own start page — the same address `linux/Sources/SixBrowser/BrowserModel`
    /// opens a fresh column on.
    public static let startURL = "https://duckduckgo.com/"

    public static let shared = RailModel()

    let layout = NiriLayout()
    private var titles: [UUID: String] = [:]
    private var urls: [UUID: String] = [:]
    private var nextTabNumber = 1
    private let profileID = UUID()

    private init() {
        layout.activeProfileID = profileID
        openColumn() // a window to land on, the way every front starts
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
}
