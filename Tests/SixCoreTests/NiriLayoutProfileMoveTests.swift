import Foundation
import Testing

@testable import SixCore

/// The layout half of moving a window to another profile.
///
/// `BrowserState` does the part that needs WebKit — the page is rebuilt against the other profile's
/// store, because a page's data store is fixed when the page is built — and hands the layout two
/// calls: take the column out of the strip it is in, put it into the other one. This is that pair,
/// and the two things about it that are easy to get wrong: the column must leave a strip that is
/// *not* the one on screen, and the row it empties must not put up the question that closing a
/// window puts up, because nothing was closed.
@MainActor
struct NiriLayoutProfileMoveTests {

    private func layout() -> NiriLayout {
        let layout = NiriLayout()
        layout.updateViewport(CGSize(width: 1600, height: 1000))
        return layout
    }

    private func columns(_ layout: NiriLayout, in profile: UUID, workspace: Int = 0) -> [UUID] {
        layout.strip(for: profile).workspaces[workspace].columns.map(\.tabID)
    }

    /// The move as it happens on screen: the window leaves the rail being looked at and is on the
    /// other profile's rail when that one comes up.
    @Test func aWindowLeavesOneStripAndJoinsTheOther() {
        let layout = layout()
        let work = UUID()
        let personal = layout.activeProfileID
        let ids = (0..<3).map { _ in UUID() }
        for id in ids { layout.insertColumn(tabID: id) }

        layout.removeColumn(tabID: ids[1], from: personal)
        layout.activeProfileID = work
        layout.insertColumn(tabID: ids[1], in: work)

        #expect(columns(layout, in: personal) == [ids[0], ids[2]])
        #expect(columns(layout, in: work) == [ids[1]])
        #expect(layout.focusedTabID == ids[1])
    }

    /// The one a plain `removeColumn` cannot do: an agent moving a window out of a profile nobody is
    /// looking at. Left in, the column would be a place on a rail pointing at a window that now
    /// stands somewhere else.
    @Test func aColumnLeavesAStripThatIsNotOnScreen() {
        let layout = layout()
        let personal = layout.activeProfileID
        let work = UUID()
        let window = UUID()
        layout.insertColumn(tabID: window, in: work)
        layout.insertColumn(tabID: UUID()) // the profile on screen has one of its own

        layout.removeColumn(tabID: window, from: work)
        layout.insertColumn(tabID: window, in: personal)

        #expect(columns(layout, in: work).isEmpty)
        #expect(columns(layout, in: personal).count == 2)
        #expect(layout.activeProfileID == personal) // taking a column out of a strip does not switch to it
    }

    /// A named row that loses its last window to a *close* asks whether it should go. Losing it to a
    /// move asks nothing: the question would arrive over the profile the window went to, about a row
    /// on the one it left, saying the window had been closed — which it had not. The row stands
    /// empty with its name, which is what answering "Keep It" would have done.
    @Test func aNamedRowThatLosesItsWindowToAMoveIsNotAskedAbout() {
        let layout = layout()
        let personal = layout.activeProfileID
        let window = UUID()
        layout.insertColumn(tabID: window)
        layout.rename(workspaceAt: 0, to: "Tickets")

        layout.removeColumn(tabID: window, from: personal)

        #expect(layout.workspaceToRemove == nil)
        #expect(layout.strip(for: personal).workspaces[0].name == "Tickets")
        #expect(layout.strip(for: personal).workspaces[0].isEmpty)
    }

    /// And the same row, emptied by a close, still asks — the move is the exception, not a change of
    /// the rule.
    @Test func aNamedRowEmptiedByACloseStillAsks() {
        let layout = layout()
        let window = UUID()
        layout.insertColumn(tabID: window)
        layout.rename(workspaceAt: 0, to: "Tickets")

        layout.removeColumn(tabID: window)

        #expect(layout.workspaceToRemove?.name == "Tickets")
    }
}
