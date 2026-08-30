import Foundation
import Testing

@testable import SixCore

/// The strip's geometry, which is the part a second front end has to reproduce exactly.
///
/// These are written against the *intent* stated in `NiriLayout`'s own comments rather than against
/// the numbers it happens to produce today: that N columns of 1/N fill the screen, that gaps are a
/// fraction of the viewport and not a point constant, and that the frames and the content width
/// agree. A GTK front computing positions from `columnFrames()` inherits exactly these promises, so
/// breaking one here is the thing that would silently desynchronise the two.
@MainActor
struct NiriLayoutGeometryTests {

    private func layout(viewport: CGSize = CGSize(width: 1600, height: 1000)) -> NiriLayout {
        let layout = NiriLayout()
        layout.updateViewport(viewport)
        return layout
    }

    private func workspace(widths: [Int]) -> NiriWorkspace {
        var workspace = NiriWorkspace()
        workspace.columns = widths.map { NiriColumn(tabID: UUID(), widthIndex: $0) }
        return workspace
    }

    // MARK: The load-bearing invariant

    /// `usableWidth` folds one gap in "so N columns of 1/N exactly fill the screen". That sentence is
    /// the whole reason the arithmetic looks odd, so it is the first thing to pin down.
    @Test(arguments: [
        (index: 0, count: 2),  // 1/2
        (index: 3, count: 1),  // 1/1
    ])
    func columnsOfOneOverNFillTheViewport(index: Int, count: Int) {
        let layout = layout()
        let column = NiriColumn(tabID: UUID(), widthIndex: index)
        let width = layout.width(of: column)

        let occupied = width * CGFloat(count)
            + layout.gap * CGFloat(count - 1)
            + 2 * layout.outerGap

        #expect(abs(occupied - layout.viewport.width) < 0.5)
    }

    // MARK: Gaps scale, they are not constants

    /// Sizes are fractions of the viewport, never point constants — otherwise the layout looks wrong
    /// on a 5K panel. Doubling the viewport doubles the gap, well clear of the small-window floor.
    @Test func gapIsAFractionOfTheViewport() {
        let small = layout(viewport: CGSize(width: 1600, height: 1000))
        let large = layout(viewport: CGSize(width: 3200, height: 2000))

        #expect(small.gap == (1600 * NiriLayout.gapFraction).rounded())
        #expect(large.gap == 2 * small.gap)
    }

    /// The floor only guards tiny windows, and below it the gap stops shrinking.
    @Test func gapHasAFloorForTinyViewports() {
        let tiny = layout(viewport: CGSize(width: 300, height: 300))
        #expect(tiny.gap == NiriLayout.minimumGap)
    }

    // MARK: Frames

    /// x starts at the outer gap and advances by width + gap; y and height are the same for every
    /// column. A front end that lays columns out from this list depends on all of it.
    @Test func columnFramesAdvanceByWidthPlusGap() {
        let layout = layout()
        let workspace = workspace(widths: [2, 0, 3, 2])
        let frames = layout.columnFrames(workspace)

        #expect(frames.count == workspace.columns.count)
        #expect(frames.first?.minX == layout.outerGap)

        for (index, frame) in frames.enumerated() {
            #expect(frame.width == layout.width(of: workspace.columns[index]))
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
        let workspace = workspace(widths: [0, 1, 2, 3, 2])
        let frames = layout.columnFrames(workspace)

        let fromFrames = (frames.last?.maxX ?? 0) + layout.outerGap
        #expect(abs(layout.contentWidth(workspace) - fromFrames) < 0.5)
    }

    @Test func emptyWorkspaceHasNoContent() {
        let layout = layout()
        #expect(layout.columnFrames(NiriWorkspace()).isEmpty)
        #expect(layout.contentWidth(NiriWorkspace()) == 0)
    }

    // MARK: Fill modes

    /// Filling overrides the preset without touching it: the widths are all still there on the way
    /// out. Both halves of that sentence are tested — the override, and the restoration.
    @Test(arguments: [NiriFill.window, NiriFill.screen])
    func fillingTakesTheWholeViewportAndIsReversible(fill: NiriFill) {
        let layout = layout()
        let column = NiriColumn(tabID: UUID(), widthIndex: 0)
        let tiled = layout.width(of: column)

        layout.setFill(fill)
        #expect(layout.fillsViewport)
        #expect(layout.gap == 0)
        #expect(layout.width(of: column) == layout.viewport.width)

        layout.setFill(.tiled)
        #expect(!layout.fillsViewport)
        #expect(layout.width(of: column) == tiled)
    }

    /// The overview is a way of looking at the strip, not a layout of its own, so it reports the
    /// tiled geometry even while a fill is set.
    @Test func overviewShowsTiledGeometry() {
        let layout = layout()
        layout.setFill(.screen)
        layout.isOverview = true

        #expect(layout.showsFill == .tiled)
        #expect(!layout.showsFullscreen)
    }

    // MARK: Width presets

    /// A column asking for a preset outside the table is clamped rather than trapping — the index is
    /// persisted state, and a file written by a future version must not crash an older one.
    @Test(arguments: [-5, -1, 4, 99])
    func outOfRangeWidthIndexIsClamped(index: Int) {
        let layout = layout()
        let column = NiriColumn(tabID: UUID(), widthIndex: index)
        let width = layout.width(of: column)

        let widths = NiriLayout.widthPresets.map {
            layout.width(of: NiriColumn(tabID: UUID(), widthIndex: NiriLayout.widthPresets.firstIndex(of: $0)!))
        }
        #expect(widths.contains(width))
    }

    @Test func widthPresetsAreOrderedAndNamed() {
        #expect(NiriLayout.widthPresets == NiriLayout.widthPresets.sorted())
        #expect(NiriLayout.widthPresetTitles.count == NiriLayout.widthPresets.count)
        #expect(NiriLayout.widthPresets.indices.contains(NiriLayout.defaultWidthIndex))
    }

    /// Even on a viewport too small for the fraction, a column keeps a usable minimum.
    @Test func narrowViewportKeepsAMinimumColumnWidth() {
        let layout = layout(viewport: CGSize(width: 320, height: 240))
        let column = NiriColumn(tabID: UUID(), widthIndex: 0)

        #expect(layout.width(of: column) >= 280)
        #expect(layout.columnHeight >= 200)
    }
}
