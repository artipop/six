import Foundation
import Testing

@testable import SixCore

/// The strip's geometry, which is the part a second front end has to reproduce exactly.
///
/// These are written against the *intent* stated in `TilingLayout`'s own comments rather than against
/// the numbers it happens to produce today: that a window is a screen's worth of page and there is
/// nothing narrower to choose, that gaps are a fraction of the viewport and not a point constant,
/// and that the frames and the content width agree. A GTK front computing positions from
/// `columnFrames()` inherits exactly these promises, so breaking one here is the thing that would
/// silently desynchronise the two.
@MainActor
struct TilingLayoutGeometryTests {

    private func layout(viewport: CGSize = CGSize(width: 1600, height: 1000)) -> TilingLayout {
        let layout = TilingLayout()
        layout.updateViewport(viewport)
        return layout
    }

    private func workspace(count: Int) -> TilingWorkspace {
        var workspace = TilingWorkspace()
        workspace.columns = (0..<count).map { _ in TilingColumn(tabID: UUID()) }
        return workspace
    }

    /// A strip of `count` windows, left to right, with the last one focused.
    @discardableResult
    private func fill(_ layout: TilingLayout, _ count: Int) -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        for id in ids { layout.insertColumn(tabID: id) }
        return ids
    }

    // MARK: The load-bearing invariant

    /// One window, one screen: a column is the viewport with the outer gaps taken off it, so exactly
    /// one of them fits and the next one starts a screen away. There is no fraction to choose, which
    /// is the whole of the width story.
    @Test func aColumnIsTheScreenLessItsGaps() {
        let layout = layout()

        #expect(abs(layout.columnWidth + 2 * layout.outerGap - layout.viewport.width) < 0.5)
    }

    // MARK: Gaps scale, they are not constants

    /// Sizes are fractions of the viewport, never point constants — otherwise the layout looks wrong
    /// on a 5K panel. Doubling the viewport doubles the gap, well clear of the small-window floor.
    @Test func gapIsAFractionOfTheViewport() {
        let small = layout(viewport: CGSize(width: 1600, height: 1000))
        let large = layout(viewport: CGSize(width: 3200, height: 2000))

        #expect(small.gap == (1600 * TilingLayout.gapFraction).rounded())
        #expect(large.gap == 2 * small.gap)
    }

    /// The floor only guards tiny windows, and below it the gap stops shrinking.
    @Test func gapHasAFloorForTinyViewports() {
        let tiny = layout(viewport: CGSize(width: 300, height: 300))
        #expect(tiny.gap == TilingLayout.minimumGap)
    }

    // MARK: Frames

    /// x starts at the outer gap and advances by width + gap; y and height are the same for every
    /// column. A front end that lays columns out from this list depends on all of it.
    @Test func columnFramesAdvanceByWidthPlusGap() {
        let layout = layout()
        let workspace = workspace(count: 4)
        let frames = layout.columnFrames(workspace)

        #expect(frames.count == workspace.columns.count)
        #expect(frames.first?.minX == layout.outerGap)

        for (index, frame) in frames.enumerated() {
            #expect(frame.width == layout.columnWidth)
            #expect(frame.minY == layout.outerGap)
            #expect(frame.height == layout.columnHeight)
            if index > 0 {
                let previous = frames[index - 1]
                #expect(abs(frame.minX - (previous.maxX + layout.gap)) < 0.5)
            }
        }
    }

    /// `contentWidth` and `columnFrames` are two ways of measuring the same strip, and a front end
    /// uses the first to size its canvas and the second to place children inside it. They must agree.
    @Test func contentWidthAgreesWithTheFrames() {
        let layout = layout()
        let workspace = workspace(count: 5)
        let frames = layout.columnFrames(workspace)

        let fromFrames = (frames.last?.maxX ?? 0) + layout.outerGap
        #expect(abs(layout.contentWidth(workspace) - fromFrames) < 0.5)
    }

    @Test func emptyWorkspaceHasNoContent() {
        let layout = layout()
        #expect(layout.columnFrames(TilingWorkspace()).isEmpty)
        #expect(layout.contentWidth(TilingWorkspace()) == 0)
    }

    // MARK: Fill modes

    /// Filling takes the gaps and gives the page what they were holding, and gives them back on the
    /// way out. That difference — a gap and a corner radius — is the whole of what the two modes are
    /// about.
    @Test func fillingTakesTheWholeViewportAndIsReversible() {
        let layout = layout()
        let tiled = layout.columnWidth

        layout.setFill(.window)
        #expect(layout.fillsViewport)
        #expect(layout.gap == 0)
        #expect(layout.columnWidth == layout.viewport.width)

        layout.setFill(.tiled)
        #expect(!layout.fillsViewport)
        #expect(layout.columnWidth == tiled)
        #expect(tiled < layout.viewport.width) // tiled is the same page with room to breathe
    }

    /// The overview is a way of looking at the row, not a layout of its own, so it reports the
    /// tiled geometry even while a fill is set.
    @Test func overviewShowsTiledGeometry() {
        let layout = layout()
        layout.setFill(.window)
        layout.isOverview = true

        #expect(layout.showsFill == .tiled)
        #expect(!layout.fillsViewport)
    }

    // MARK: The place a new window would take

    /// The `+` at the end of an overview row stands where the window it opens will: one gap past
    /// the last column, at a column's own size.
    @Test func theAppendPlaceFollowsTheLastColumn() {
        let layout = layout()
        fill(layout, 3)
        let frames = layout.columnFrames(layout.workspaces[0])

        let place = layout.appendFrame(inWorkspaceAt: 0)

        #expect(place?.minX == frames.last!.maxX + layout.gap)
        #expect(place?.width == layout.columnWidth)
        #expect(place?.height == layout.columnHeight)
    }

    /// An empty row has one too, and it is centred: the row's content is a point in the middle of
    /// the screen, so the place hangs half to each side of it.
    @Test func anEmptyRowsPlaceIsCentred() {
        let layout = layout()

        let place = layout.appendFrame(inWorkspaceAt: 0)
        #expect(place?.midX == 0)
        #expect(place?.width == layout.columnWidth)
        #expect(layout.appendFrame(inWorkspaceAt: 1) == nil)
    }

    /// The overview lays a row out with a column's worth of slack, so the windows keep the middle
    /// and half of the place shows past the edge.
    @Test func theOverviewLeavesHalfThePlaceShowing() {
        let layout = layout()
        fill(layout, 3)
        let row = layout.workspaces[0]
        let place = layout.appendFrame(inWorkspaceAt: 0)!

        let slack = (layout.overviewWidth(row) - layout.contentWidth(row)) / 2
        #expect(slack == layout.columnWidth / 2)
        #expect(abs((layout.contentWidth(row) + slack) - place.midX) < 0.5)
    }

    /// Every card of every row, in the one space the overview's pointer and its badges both read.
    @Test func theCanvasHasAPlaceForEveryWindow() {
        let layout = layout()
        fill(layout, 2)
        layout.moveColumnToWorkspace(1) // the last of the two moves down and makes a second row
        layout.isOverview = true

        let places = layout.canvasPlaces()

        #expect(places.count == 2)
        #expect(Set(places.map(\.tabID)).count == 2)
        // The second row is laid out a screen below the first, so no two rows overlap.
        #expect(places[0].frame.minY < places[1].frame.minY)
    }

    // MARK: Floors

    /// Even on a viewport too small for the gaps it wants, a window keeps a usable minimum.
    @Test func narrowViewportKeepsAMinimumColumnWidth() {
        let layout = layout(viewport: CGSize(width: 320, height: 240))

        #expect(layout.columnWidth >= 280)
        #expect(layout.columnHeight >= 200)
    }
}
