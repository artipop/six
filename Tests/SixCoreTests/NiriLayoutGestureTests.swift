import Foundation
import Testing

@testable import SixCore

/// The three things the mouse does to the strip that are arithmetic rather than drawing: opening a
/// window at the near end instead of the far one, looking ahead at a window that isn't there yet, and
/// carrying one across the overview.
///
/// Like the geometry tests, these are written against the intent rather than the numbers: a second
/// front end drawing from `arrangement()`, `newColumnFrame` and `carriedCardFrame` inherits exactly
/// these promises, and they are the ones that would silently desynchronise the two.
@MainActor
struct NiriLayoutGestureTests {

    private func layout(viewport: CGSize = CGSize(width: 1600, height: 1000)) -> NiriLayout {
        let layout = NiriLayout()
        layout.updateViewport(viewport)
        return layout
    }

    /// A strip of `count` windows, left to right, with the last one focused.
    @discardableResult
    private func fill(_ layout: NiriLayout, _ count: Int) -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        for id in ids { layout.insertColumn(tabID: id) }
        return ids
    }

    private func columns(_ layout: NiriLayout, workspace: Int = 0) -> [UUID] {
        layout.workspaces[workspace].columns.map(\.tabID)
    }

    // MARK: A window at the near end

    /// The `+` at the near end of the strip opens its window *there*. Right stays niri's own answer
    /// and the default, so both directions are one insertion apart.
    @Test func newWindowOpensOnTheSideItWasAskedFor() {
        let layout = layout()
        let ids = fill(layout, 2) // [0, 1], focus on 1

        let left = UUID()
        layout.insertColumn(tabID: left, on: .left)
        #expect(columns(layout) == [ids[0], left, ids[1]])
        #expect(layout.focusedTabID == left) // the window you asked for is the one you are looking at

        let right = UUID()
        layout.insertColumn(tabID: right, on: .right)
        #expect(columns(layout) == [ids[0], left, right, ids[1]])
        #expect(layout.focusedTabID == right)
    }

    /// An empty row has one place, whichever side is asked for.
    @Test func theFirstWindowGoesTheSameWayRoundEitherSide() {
        let layout = layout()
        let id = UUID()
        layout.insertColumn(tabID: id, on: .left)
        #expect(columns(layout) == [id])
        #expect(layout.focusedTabID == id)
    }

    // MARK: Looking ahead

    /// The outline stands where the window would: beyond the last column for the far `+`, before the
    /// first for the near one, one gap out and at the width a new window actually opens at.
    @Test func theOutlineStandsWhereTheWindowWould() {
        let layout = layout()
        fill(layout, 3)
        let frames = layout.columnFrames(layout.focusedWorkspace!)

        layout.newColumnHover = 1
        let far = layout.newColumnFrame
        #expect(far?.width == layout.columnWidth)
        #expect(abs((far?.minX ?? 0) - (frames.last!.maxX + layout.gap)) < 0.5)
        #expect(far?.height == layout.columnHeight)

        layout.newColumnHover = -1
        let near = layout.newColumnFrame
        #expect(abs((near?.maxX ?? 0) - (frames.first!.minX - layout.gap)) < 0.5)
    }

    /// The lean is towards the outline and goes exactly as far as the glance a window opening behind
    /// gets — one distance for both, because they are the same sentence. Its sign is
    /// `horizontalPreview`'s: the far end is reached by scrolling further along the strip, which the
    /// columns are drawn as a *subtraction*.
    @Test func theLeanIsTowardsTheOutlineAndNoFurtherThanAGlance() {
        let layout = layout(viewport: CGSize(width: 900, height: 700))
        fill(layout, 2)

        layout.newColumnHover = 1
        #expect(layout.newColumnLean < 0)
        #expect(abs(abs(layout.newColumnLean) - layout.peekAmount) < 0.5)

        layout.newColumnHover = -1
        #expect(layout.newColumnLean > 0)
    }

    /// And it is a fraction of the viewport, like every other size in the layout — a glance is a
    /// proportion of the screen, not a count of points.
    @Test func theGlanceScalesWithTheScreen() {
        let small = layout(viewport: CGSize(width: 1600, height: 1000))
        let large = layout(viewport: CGSize(width: 3200, height: 2000))
        #expect(large.peekAmount == 2 * small.peekAmount)
        #expect(layout(viewport: CGSize(width: 400, height: 400)).peekAmount == NiriLayout.minimumPeek)
    }

    /// The peek is let go of by name, so the pointer going straight from one end of the strip to the
    /// other cannot leave it leaning the wrong way.
    @Test func onlyTheSideThatTookThePeekLetsGoOfIt() {
        let layout = layout()
        layout.hoverNewColumn(1, true)
        layout.hoverNewColumn(-1, false) // the other button's exit
        #expect(layout.newColumnHover == 1)
        layout.hoverNewColumn(1, false)
        #expect(layout.newColumnHover == 0)
    }

    // MARK: Carrying a window

    private func carrying(_ layout: NiriLayout, _ ids: [UUID], from index: Int) -> UUID {
        layout.isOverview = true
        layout.beginColumnDrag(tabID: ids[index])
        return ids[index]
    }

    /// One slot to the right: the gap opens where the window would land, the row it came from closes
    /// up, and the strip itself is not touched until it is let go.
    @Test func carryingAWindowOpensAGapAndChangesNothingElse() {
        let layout = layout()
        let ids = fill(layout, 3)
        let carried = carrying(layout, ids, from: 0)

        let frames = layout.columnFrames(layout.workspaces[0])
        // Just past the middle of the window to its right: that is the line, and crossing it is what
        // makes one window have gone past another.
        layout.updateColumnDrag(translation: CGSize(width: frames[1].midX - frames[0].midX + 1, height: 0))

        #expect(layout.columnDrag?.toIndex == 1)
        #expect(layout.columnDrag?.toWorkspace == 0)
        #expect(layout.arrangement(workspaceAt: 0).map(\.tabID) == [ids[1], carried, ids[2]])
        #expect(columns(layout) == ids) // the strip has not moved yet

        layout.commitColumnDrag()
        #expect(columns(layout) == [ids[1], carried, ids[2]])
        #expect(layout.focusedTabID == carried) // the focus went with the hand
    }

    /// The card stays under the pointer: where it was lifted from, plus how far the pointer has gone.
    @Test func theCarriedCardFollowsThePointerExactly() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids, from: 2)
        let lifted = layout.carriedCardFrame

        let travel = CGSize(width: -240, height: 60)
        layout.updateColumnDrag(translation: travel)
        let moved = layout.carriedCardFrame

        #expect(abs((moved?.minX ?? 0) - ((lifted?.minX ?? 0) + travel.width)) < 0.5)
        #expect(abs((moved?.minY ?? 0) - ((lifted?.minY ?? 0) + travel.height)) < 0.5)
        #expect(moved?.width == lifted?.width)
    }

    /// A row down is the workspace below: the rows are a screen and a gap apart, and the one whose
    /// middle the card's middle is nearest is the one it would land in.
    @Test func carryingAWindowDownAScreenMovesItToTheNextWorkspace() {
        let layout = layout()
        let ids = fill(layout, 3)
        let carried = carrying(layout, ids, from: 0)

        layout.updateColumnDrag(translation: CGSize(width: 0, height: layout.viewport.height + layout.workspaceSpacing))
        #expect(layout.columnDrag?.toWorkspace == 1)
        #expect(layout.columnDrag?.toIndex == 0)
        #expect(layout.arrangement(workspaceAt: 0).map(\.tabID) == [ids[1], ids[2]])
        #expect(layout.arrangement(workspaceAt: 1).map(\.tabID) == [carried])

        layout.commitColumnDrag()
        #expect(columns(layout, workspace: 0) == [ids[1], ids[2]])
        #expect(columns(layout, workspace: 1) == [carried])
        #expect(layout.focusedWorkspaceIndex == 1) // you are looking at where you put it
        #expect(layout.focusedTabID == carried)
        // And niri's dynamic workspaces still hold: exactly one empty row at the end.
        #expect(layout.workspaces.count == 3)
        #expect(layout.workspaces.last?.isEmpty == true)
    }

    /// Picked up and put back down: nothing moved, and nothing was reported as having moved.
    @Test func aCarryThatGoesNowhereChangesNothing() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids, from: 1)
        layout.updateColumnDrag(translation: CGSize(width: 4, height: 4))

        #expect(layout.commitColumnDrag() == false)
        #expect(columns(layout) == ids)
        #expect(layout.columnDrag == nil)
    }

    /// Let go of the drag, not of the window.
    @Test func cancellingACarryLeavesTheStripAlone() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids, from: 0)
        layout.updateColumnDrag(translation: CGSize(width: 900, height: 0))
        layout.cancelColumnDrag()

        #expect(layout.columnDrag == nil)
        #expect(layout.carriedCardFrame == nil)
        #expect(columns(layout) == ids)
        #expect(layout.arrangement(workspaceAt: 0).map(\.tabID) == ids)
    }

    /// Only in the overview: in the strip a window is a page being read, and a drag on it belongs to
    /// the page.
    @Test func aWindowIsOnlyPickedUpInTheOverview() {
        let layout = layout()
        let ids = fill(layout, 2)
        layout.beginColumnDrag(tabID: ids[0])
        #expect(layout.columnDrag == nil)
    }
}
