import Foundation
import Testing

@testable import SixCore

/// Two windows sharing one column, and every way in and out of that.
///
/// The rule the whole feature rests on is that **a column is still one screen's worth of row**: a
/// split changes what is inside a column and nothing about where columns are, so every promise the
/// geometry tests make about the strip has to survive one. The rest is about the two halves being
/// windows in their own right — walked to and closed one at a time — because the alternative
/// reading, a split as a single window with two pages in it, is the one that would make ⌥→ skip a
/// page and ⌘W close two. Where the pair *is* one thing is in moving it: a split carried across the
/// overview or sent to another row goes as a pair, because two pages put side by side is an
/// arrangement somebody made, and ⌥S is the way to take it apart.
@MainActor
struct TilingLayoutSplitTests {

    private func layout(viewport: CGSize = CGSize(width: 1600, height: 1000)) -> TilingLayout {
        let layout = TilingLayout()
        layout.updateViewport(viewport)
        return layout
    }

    /// A strip of `count` windows, left to right, with the last one focused.
    @discardableResult
    private func fill(_ layout: TilingLayout, _ count: Int) -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        for id in ids { layout.insertColumn(tabID: id) }
        return ids
    }

    /// The windows of the row, column by column — a split column is one entry with two windows in it.
    private func row(_ layout: TilingLayout, workspace: Int = 0) -> [[UUID]] {
        layout.workspaces[workspace].columns.map(\.tabIDs)
    }

    // MARK: Making one

    /// ⌥S takes in the window the row would have walked to, and leaves the focus where it is: the
    /// page being read is the reason the key was pressed, not the one that arrives beside it.
    @Test func theWindowNextAlongComesInBesideThisOne() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1) // the middle one, with a window on each side

        #expect(layout.toggleSplit())
        #expect(row(layout) == [[ids[0]], [ids[1], ids[2]]])
        #expect(layout.focusedTabID == ids[1])
        #expect(layout.isSplit)
    }

    /// The last window in the row has nothing to its right, so it takes the one on its left — and
    /// that window arrives on the *left*, keeping the order the row had. A split that reordered the
    /// two windows would be a split that moved a page you were looking at.
    @Test func theLastWindowInTheRowTakesTheOneBeforeIt() {
        let layout = layout()
        let ids = fill(layout, 2) // focus on the last

        #expect(layout.toggleSplit())
        #expect(row(layout) == [[ids[0], ids[1]]])
        #expect(layout.focusedTabID == ids[1])
    }

    /// One window in the row is nothing to split with, and the key says so the way every other
    /// gesture with nowhere to go says it: the end of the row lights up and nothing moves.
    @Test func aRowOfOneHasNothingToSplitWith() {
        let layout = layout()
        let ids = fill(layout, 1)

        #expect(!layout.canSplit)
        #expect(!layout.toggleSplit())
        #expect(row(layout) == [[ids[0]]])
    }

    /// Two is the ceiling: the second press is an unsplit, so a column can never collect a third.
    @Test func aColumnNeverHoldsMoreThanTwo() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1)
        layout.toggleSplit()
        layout.toggleSplit()

        #expect(row(layout).allSatisfy { $0.count <= 2 })
        #expect(row(layout).flatMap { $0 }.count == ids.count) // and no window was lost on the way
    }

    // MARK: Taking one apart

    /// The right-hand window steps out into a column of its own, immediately to the right, and the
    /// focus follows whichever of the two had it.
    @Test func theSecondPressPutsThemBackInTheRow() {
        let layout = layout()
        let ids = fill(layout, 2)
        layout.toggleSplit() // [0 | 1], focus on 1 — the right half

        #expect(layout.toggleSplit())
        #expect(row(layout) == [[ids[0]], [ids[1]]])
        #expect(layout.focusedTabID == ids[1]) // it went with the window, not with the place
    }

    /// Closing half of a split is closing one window: the other stays where it stood, with the whole
    /// column to itself.
    @Test func closingOneHalfLeavesTheOtherWhereItStood() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1)
        layout.toggleSplit() // [0] [1 | 2]

        layout.removeColumn(tabID: ids[2])
        #expect(row(layout) == [[ids[0]], [ids[1]]])
        #expect(layout.focusedTabID == ids[1])
    }

    // MARK: Walking the row through one

    /// A split column is one stop and not two. ⌥→ from the window before it lands on the pair and
    /// the next ⌥→ leaves it: the other half is not somewhere the row leads, it is on screen beside
    /// the one being read, a click away. Stepping into it moved nothing and the key read as dead.
    @Test func aSplitIsOneStopInTheRow() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1)
        layout.toggleSplit() // [0] [1 | 2], focus on 1
        layout.focusColumn(-1) // to the window before the pair

        #expect(layout.focusedTabID == ids[0])
        layout.focusColumn(1)
        #expect(layout.focusedTabID == ids[1])
        layout.focusColumn(1) // and there is nothing past the pair: its other half is not a stop
        #expect(layout.focusedTabID == ids[1])
        layout.focusColumn(-1)
        #expect(layout.focusedTabID == ids[0])
    }

    /// And the column keeps the half it was left on. Which of the two windows is being read is
    /// something the hand said by clicking; walking away along the row and back is not a reason for
    /// the row to say something else.
    @Test func aSplitKeepsTheHalfItWasLeftOn() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-2)
        layout.toggleSplit() // [0 | 1] [2], focus on 0
        layout.focusColumn(1) // out of the pair and onto the last window

        #expect(layout.focusedTabID == ids[2])
        layout.focusColumn(-1)
        #expect(layout.focusedTabID == ids[0]) // the half it was left on
    }

    /// ⌥⇧→ inside a split swaps its halves — one place along, and inside a column there is exactly
    /// one place to go. The focus stays on the window that moved.
    @Test func theMoveInsideASplitSwapsItsHalves() {
        let layout = layout()
        let ids = fill(layout, 2)
        layout.toggleSplit() // [0 | 1], focus on 1

        layout.moveColumn(-1)
        #expect(row(layout) == [[ids[1], ids[0]]])
        #expect(layout.focusedTabID == ids[1])
    }

    /// ⌥⇧↓ moves the column in front of you, and a split is a column: the pair arrives in the other
    /// row still side by side, with the focus on the half that had it. Sending one half off on its
    /// own would take an arrangement apart in passing, and leave no way back to it.
    @Test func thePairGoesToAnotherWorkspaceTogether() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.toggleSplit() // [0] [1 | 2], focus on 2 — a window stays behind, so the row lives on

        layout.moveColumnToWorkspace(1)
        #expect(row(layout, workspace: 0) == [[ids[0]]])
        #expect(row(layout, workspace: 1) == [[ids[1], ids[2]]])
        #expect(layout.focusedTabID == ids[2])
        #expect(layout.isSplit)
    }

    // MARK: The geometry

    /// The two halves fill exactly the column one window would have had, split by a gap of their
    /// own — so the row's own arithmetic is untouched by a split, and the strip is as long either
    /// way.
    @Test func theTwoHalvesFillOneColumn() {
        let layout = layout()
        let ids = fill(layout, 2)
        let before = layout.contentWidth(layout.focusedWorkspace!)
        layout.toggleSplit()

        let workspace = layout.focusedWorkspace!
        let frame = layout.columnFrames(workspace)[0]
        let panes = layout.paneFrames(workspace.columns[0], in: frame)

        #expect(panes.count == 2)
        #expect(abs(panes[0].width + panes[1].width + layout.paneGap - frame.width) < 1)
        #expect(abs(panes[1].minX - panes[0].maxX - layout.paneGap) < 1)
        #expect(panes[0].height == frame.height)
        #expect(layout.contentWidth(workspace) < before) // one column where there were two
        #expect(ids.count == 2)
    }

    /// The gap inside a column is deliberately smaller than the one between columns: at the same
    /// width a split would read as two windows standing next to each other, and proximity is the
    /// whole of what says otherwise.
    @Test func theGapInsideAColumnIsTighterThanTheOneBetweenThem() {
        let small = layout()
        #expect(small.paneGap < small.gap)
        // And it is a fraction of the viewport like every other size here, with a floor under it.
        let large = layout(viewport: CGSize(width: 3200, height: 2000))
        #expect(large.paneGap > small.paneGap)
    }

    /// Both halves are on screen, so both are pinned and neither is a card: a split with a picture
    /// in one half is a split that did not happen.
    @Test func bothHalvesAreWindowsTheStripIsShowing() {
        let layout = layout()
        let ids = fill(layout, 2)
        layout.toggleSplit()

        #expect(layout.visibleTabIDs == Set(ids))
        #expect(layout.focusedWorkspace?.focusedColumn?.tabIDs == ids)
    }

    // MARK: Carrying a window onto another

    private func carrying(_ layout: TilingLayout, _ id: UUID) {
        layout.isOverview = true
        layout.beginColumnDrag(tabID: id)
    }

    /// A window let go over the *middle* of another joins it: by then the two cards are all but on
    /// top of each other, which is what a person means by putting one window on another.
    @Test func aWindowDroppedOnAnotherJoinsIt() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids[0])

        let frames = layout.columnFrames(layout.workspaces[0])
        layout.updateColumnDrag(translation: CGSize(width: frames[2].midX - frames[0].midX, height: 0))
        #expect(layout.columnDrag?.joins != nil)
        // The row shows it before it happens: the window it would join opens its other half, and
        // that half stays empty, because the window that would fill it is in the air.
        #expect(layout.arrangement(workspaceAt: 0).map(\.tabIDs) == [[ids[1]], [ids[2], ids[0]]])

        layout.commitColumnDrag()
        #expect(row(layout) == [[ids[1]], [ids[2], ids[0]]])
        #expect(layout.focusedTabID == ids[0]) // the window that was let go is the one in front of you
    }

    /// Held over the left of a window, it lands on the left of it — the drop reads as a place and
    /// not only as a target.
    @Test func theSideItIsHeldOverIsTheSideItLandsOn() {
        let layout = layout()
        let ids = fill(layout, 2)
        carrying(layout, ids[1])

        let frames = layout.columnFrames(layout.workspaces[0])
        layout.updateColumnDrag(translation: CGSize(width: frames[0].midX - frames[1].midX - frames[0].width * 0.1,
                                                    height: 0))
        layout.commitColumnDrag()
        #expect(row(layout) == [[ids[1], ids[0]]])
    }

    /// And a card let go beside a window still stands beside it: the middle half of a card joins,
    /// the quarter at each end does not, so reordering the row goes on working the way it did.
    @Test func aWindowDroppedBesideAnotherStandsBesideIt() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids[0])

        let frames = layout.columnFrames(layout.workspaces[0])
        layout.updateColumnDrag(translation: CGSize(width: frames[1].midX - frames[0].midX + frames[1].width * 0.35,
                                                    height: 0))
        #expect(layout.columnDrag?.joins == nil)
        layout.commitColumnDrag()
        #expect(row(layout) == [[ids[1]], [ids[0]], [ids[2]]])
    }

    /// A column with two windows in it has no room for a third, so it is not a place to drop one.
    @Test func aColumnThatIsAlreadyTwoIsNotADropTarget() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1)
        layout.toggleSplit() // [0] [1 | 2]
        layout.focus(tabID: ids[0])
        carrying(layout, ids[0])

        let frames = layout.columnFrames(layout.workspaces[0])
        layout.updateColumnDrag(translation: CGSize(width: frames[1].midX - frames[0].midX, height: 0))
        #expect(layout.columnDrag?.joins == nil)
    }

    /// Any two windows, and not only two that were already neighbours: the overview is where a row
    /// is rearranged, so a window carried onto one standing on *another workspace* joins it there.
    /// This is the only way in that does not go through "the window next along" — ⌥S has no reach.
    @Test func aWindowCanJoinOneOnAnotherWorkspace() {
        let layout = layout()
        let ids = fill(layout, 2)
        // A window a row below, to be joined from up here.
        let below = UUID()
        layout.insertColumn(tabID: below, in: layout.activeProfileID, workspace: 1, focus: false)
        carrying(layout, ids[0])

        // In canvas points, and not in either row's content space: the two rows are scrolled
        // differently, so the distance between two windows is only the same number once both have
        // been put on the canvas the pointer moves across.
        let from = layout.canvasX(content: layout.columnFrames(layout.workspaces[0])[0].midX, workspace: 0)
        let onto = layout.canvasX(content: layout.columnFrames(layout.workspaces[1])[0].midX, workspace: 1)
        layout.updateColumnDrag(translation: CGSize(width: onto - from,
                                                    height: layout.viewport.height + layout.workspaceSpacing))
        #expect(layout.columnDrag?.toWorkspace == 1)
        #expect(layout.columnDrag?.joins != nil)

        layout.commitColumnDrag()
        #expect(row(layout, workspace: 0) == [[ids[1]]])
        #expect(row(layout, workspace: 1) == [[below, ids[0]]])
        #expect(layout.focusedTabID == ids[0]) // and you are looking at the row it went to
    }

    /// Either half picks the pair up, and the pair is what lands: the card in the hand is a whole
    /// column, the row it left has no half standing in it, and the row it arrives in gets both.
    @Test func aSplitIsCarriedWhole() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.toggleSplit() // [0] [1 | 2]
        carrying(layout, ids[2]) // by its right half

        #expect(layout.columnDrag?.tabIDs == [ids[1], ids[2]])
        // And the card is a column's worth of card, not a half's.
        #expect(abs((layout.carriedCardFrame?.width ?? 0) - layout.columnWidth) < 1)

        layout.updateColumnDrag(translation: CGSize(width: 0, height: layout.viewport.height + 200))
        #expect(layout.columnDrag?.toWorkspace == 1)
        // The row it came from has no half standing in it: what left, left whole.
        #expect(layout.arrangement(workspaceAt: 0).map(\.tabIDs) == [[ids[0]]])
        #expect(layout.arrangement(workspaceAt: 1).map(\.tabIDs) == [[ids[1], ids[2]]])

        layout.commitColumnDrag()
        #expect(row(layout, workspace: 0) == [[ids[0]]])
        #expect(row(layout, workspace: 1) == [[ids[1], ids[2]]])
        #expect(layout.focusedTabID == ids[2]) // the half the hand took hold of
    }

    /// A pair has nowhere to be put *inside* another column — two is the ceiling — so carrying one
    /// over the middle of a window means the same as carrying it beside one: it stands next to it.
    @Test func aCarriedPairNeverJoinsAnotherWindow() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-2)
        layout.toggleSplit() // [0 | 1] [2], focus on 0
        carrying(layout, ids[0])

        let frames = layout.columnFrames(layout.workspaces[0])
        // Just past that window's middle, which is as deep into the join zone as a drop can get.
        layout.updateColumnDrag(translation: CGSize(width: frames[1].midX - frames[0].midX + 2, height: 0))
        #expect(layout.columnDrag?.joins == nil)
        // The outline is the whole column it would stand in, drawn around both halves at once.
        #expect(abs((layout.dropSlotFrame?.width ?? 0) - layout.columnWidth) < 1)

        layout.commitColumnDrag()
        #expect(row(layout) == [[ids[2]], [ids[0], ids[1]]])
    }

    /// The answer is wider to leave than to enter, so a hand resting on the line between "join this
    /// window" and "stand beside it" does not flip between them. Those two answers are a relayout of
    /// the whole row apart, and flipping between them is what a drag that thinks about it looks like.
    @Test func theJoinDoesNotFlickerOnItsOwnBoundary() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids[0])

        let frames = layout.columnFrames(layout.workspaces[0])
        let to = { (fraction: CGFloat) in
            layout.updateColumnDrag(translation: CGSize(
                width: frames[1].midX - frames[0].midX + frames[1].width * fraction, height: 0))
        }
        // Inside the zone, and it takes.
        to(0.2)
        #expect(layout.columnDrag?.joins != nil)
        // Just outside the *entering* threshold, where a single line would have let go: it holds.
        to(0.28)
        #expect(layout.columnDrag?.joins != nil)
        // Past the leaving one, and only then.
        to(0.4)
        #expect(layout.columnDrag?.joins == nil)
        // And coming back needs the narrower threshold again, not the wider one.
        to(0.28)
        #expect(layout.columnDrag?.joins == nil)
        to(0.2)
        #expect(layout.columnDrag?.joins != nil)
    }

    /// The outline the drop draws is the *place*, at the size the window is about to be: half a
    /// column when it would join one, a whole column when it would stand beside it. Taken from the
    /// arrangement, so it cannot disagree with the row drawn under it.
    @Test func theDropOutlineIsTheHalfItWouldLandIn() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids[0])
        let whole = layout.columnFrames(layout.workspaces[0])[1]

        // Beside the middle window: a whole column's worth of outline.
        layout.updateColumnDrag(translation: CGSize(width: whole.midX - layout.columnFrames(layout.workspaces[0])[0].midX
                                                        + whole.width * 0.4, height: 0))
        #expect(layout.columnDrag?.joins == nil)
        #expect(abs((layout.dropSlotFrame?.width ?? 0) - layout.columnWidth) < 1)

        // On its middle: half of one, and the half it is being held over.
        layout.updateColumnDrag(translation: CGSize(width: whole.midX - layout.columnFrames(layout.workspaces[0])[0].midX
                                                        + whole.width * 0.1, height: 0))
        #expect(layout.columnDrag?.joins != nil)
        let slot = layout.dropSlotFrame
        #expect(abs((slot?.width ?? 0) - (layout.columnWidth - layout.paneGap) / 2) < 1.5)
        #expect(slot?.height == layout.columnHeight)
        // Held right of that window's middle, so it is the right half — said against the row as it
        // is being drawn, which is the only place both halves have a position at all.
        let places = layout.placements(layout.arrangement(workspaceAt: 0))
        let carried = places.first { $0.tabID == ids[0] }
        #expect(carried?.side == .right)
        #expect(abs(layout.canvasX(content: carried?.frame.minX ?? 0, workspace: 0) - (slot?.minX ?? 0)) < 0.5)
    }

    /// What the row animates its shuffle on: the answer, without the pointer position that produced
    /// it. Keyed on the drag itself, every pointer move restarted the shuffle and none of them ever
    /// finished.
    @Test func theDropTargetIgnoresWhereThePointerIs() {
        let layout = layout()
        let ids = fill(layout, 3)
        carrying(layout, ids[0])

        layout.updateColumnDrag(translation: CGSize(width: 12, height: 0))
        let first = layout.dropTarget
        layout.updateColumnDrag(translation: CGSize(width: 24, height: 0))
        #expect(layout.dropTarget == first) // the hand moved, the answer did not
        #expect(first != nil)
    }

    /// What anything drawing a window away from the row asks: what else is in its column, and
    /// which column is it. The ⌃Tab ring is built on both — one stop per column, and a card that
    /// draws the pair.
    @Test func aWindowKnowsWhatItSharesItsColumnWith() {
        let layout = layout()
        let ids = fill(layout, 3)
        layout.focusColumn(-1)
        layout.toggleSplit() // [0] [1 | 2]

        #expect(layout.columnMates(of: ids[1]) == [ids[1], ids[2]])
        #expect(layout.columnMates(of: ids[2]) == [ids[1], ids[2]]) // left to right, from either half
        #expect(layout.columnMates(of: ids[0]) == [ids[0]])
        // The two halves are one column and the window beside them is another: that is the whole of
        // what tells "sharing a column" from "standing next to each other".
        #expect(layout.columnID(of: ids[1]) == layout.columnID(of: ids[2]))
        #expect(layout.columnID(of: ids[0]) != layout.columnID(of: ids[1]))
        // A window this strip has never heard of is a column of one, not an empty answer: the
        // callers are views, and a card with nothing to draw is worse than a card drawing the one
        // window it was given.
        let stranger = UUID()
        #expect(layout.columnMates(of: stranger) == [stranger])
        #expect(layout.columnID(of: stranger) == nil)
    }

    // MARK: What is written down

    /// A column on disk was a `tabID` and nothing else until it could hold two, and a session file
    /// outlives the build that wrote it. The old shape has to decode, or a relaunch after an update
    /// is a row with nothing on it.
    @Test func aColumnWrittenBeforeSplitsExistedStillReads() throws {
        let id = UUID()
        let old = Data(#"{"tabID":"\#(id.uuidString)"}"#.utf8)
        let column = try JSONDecoder().decode(TilingColumn.self, from: old)

        #expect(column.tabID == id)
        #expect(!column.isSplit)
        #expect(column.focusedTabID == id)
    }

    @Test func aSplitColumnSurvivesTheRoundTrip() throws {
        var column = TilingColumn(tabID: UUID())
        column.insert(UUID(), on: .right)
        column.pane = 1

        let again = try JSONDecoder().decode(TilingColumn.self, from: JSONEncoder().encode(column))
        #expect(again == column)
        #expect(again.id == column.id) // the identity the view tree is built on, not the window's
    }
}
