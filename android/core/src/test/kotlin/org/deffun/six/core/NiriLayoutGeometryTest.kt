package org.deffun.six.core

import java.util.UUID
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The strip's geometry, which is the part a second front end has to reproduce exactly.
 *
 * A port of `Tests/SixCoreTests/NiriLayoutGeometryTests.swift`, test for test. Like the original it
 * is written against the *intent* stated in `NiriLayout`'s own comments rather than against the
 * numbers it happens to produce today: that a window is a screen's worth of page and there is
 * nothing narrower to choose, that gaps are a fraction of the viewport and not a point constant,
 * and that the frames and the content width agree. Breaking one of these here is what would
 * silently desynchronise Android from the Mac.
 *
 * Where the two differ in shape rather than in meaning — `setFill` returns a new layout instead of
 * mutating one — the assertion is the same and only the plumbing changed.
 */
class NiriLayoutGeometryTest {

    private fun layout(viewport: Size = Size(1600.0, 1000.0)): NiriLayout =
        NiriLayout().updateViewport(viewport)

    private fun workspace(count: Int): NiriWorkspace =
        NiriWorkspace(columns = List(count) { NiriColumn(UUID.randomUUID()) })

    // MARK: The load-bearing invariant

    /**
     * One window, one screen: a column is the viewport with the outer gaps taken off it, so exactly
     * one of them fits and the next one starts a screen away. There is no fraction to choose, which
     * is the whole of the width story.
     */
    @Test
    fun aColumnIsTheScreenLessItsGaps() {
        val layout = layout()

        assertTrue(abs(layout.columnWidth + 2 * layout.outerGap - layout.viewport.width) < 0.5)
    }

    // MARK: Gaps scale, they are not constants

    /**
     * Sizes are fractions of the viewport, never point constants — otherwise the layout looks wrong
     * on a tablet. Doubling the viewport doubles the gap, well clear of the small-window floor.
     */
    @Test
    fun gapIsAFractionOfTheViewport() {
        val small = layout(Size(1600.0, 1000.0))
        val large = layout(Size(3200.0, 2000.0))

        assertEquals(Math.round(1600 * NiriLayout.GAP_FRACTION).toDouble(), small.gap)
        assertEquals(2 * small.gap, large.gap)
    }

    /** The floor only guards tiny windows, and below it the gap stops shrinking. */
    @Test
    fun gapHasAFloorForTinyViewports() {
        assertEquals(NiriLayout.MINIMUM_GAP, layout(Size(300.0, 300.0)).gap)
    }

    // MARK: Frames

    /**
     * x starts at the outer gap and advances by width + gap; y and height are the same for every
     * column. A front end that lays columns out from this list depends on all of it.
     */
    @Test
    fun columnFramesAdvanceByWidthPlusGap() {
        val layout = layout()
        val workspace = workspace(4)
        val frames = layout.columnFrames(workspace)

        assertEquals(workspace.columns.size, frames.size)
        assertEquals(layout.outerGap, frames.first().minX)

        frames.forEachIndexed { index, frame ->
            assertEquals(layout.columnWidth, frame.width)
            assertEquals(layout.outerGap, frame.minY)
            assertEquals(layout.columnHeight, frame.height)
            if (index > 0) {
                val previous = frames[index - 1]
                assertTrue(abs(frame.minX - (previous.maxX + layout.gap)) < 0.5)
            }
        }
    }

    /**
     * `contentWidth` and `columnFrames` are two ways of measuring the same strip, and a front end
     * uses the first to size its canvas and the second to place children inside it. They must agree.
     */
    @Test
    fun contentWidthAgreesWithTheFrames() {
        val layout = layout()
        val workspace = workspace(5)
        val frames = layout.columnFrames(workspace)

        val fromFrames = (frames.lastOrNull()?.maxX ?: 0.0) + layout.outerGap
        assertTrue(abs(layout.contentWidth(workspace) - fromFrames) < 0.5)
    }

    @Test
    fun emptyWorkspaceHasNoContent() {
        val layout = layout()
        assertTrue(layout.columnFrames(NiriWorkspace()).isEmpty())
        assertEquals(0.0, layout.contentWidth(NiriWorkspace()))
    }

    // MARK: Fill modes

    /**
     * Filling takes the gaps and gives the page what they were holding, and gives them back on the
     * way out. That difference — a gap and a corner radius — is the whole of what the three modes
     * are about.
     */
    @Test
    fun fillingTakesTheWholeViewportAndIsReversible() {
        for (fill in listOf(NiriFill.WINDOW, NiriFill.SCREEN)) {
            val layout = layout()
            val tiled = layout.columnWidth

            val filled = layout.setFill(fill)
            assertTrue(filled.fillsViewport)
            assertEquals(0.0, filled.gap)
            assertEquals(filled.viewport.width, filled.columnWidth)

            val restored = filled.setFill(NiriFill.TILED)
            assertFalse(restored.fillsViewport)
            assertEquals(tiled, restored.columnWidth)
            assertTrue(tiled < layout.viewport.width)
        }
    }

    /**
     * The overview is a way of looking at the strip, not a layout of its own, so it reports the
     * tiled geometry even while a fill is set.
     */
    @Test
    fun overviewShowsTiledGeometry() {
        val layout = layout().setFill(NiriFill.SCREEN).setOverview(true)

        assertEquals(NiriFill.TILED, layout.showsFill)
        assertFalse(layout.showsFullscreen)
    }

    // MARK: Floors

    /** Even on a viewport too small for the gaps it wants, a window keeps a usable minimum. */
    @Test
    fun narrowViewportKeepsAMinimumColumnWidth() {
        val layout = layout(Size(320.0, 240.0))

        assertTrue(layout.columnWidth >= 280.0)
        assertTrue(layout.columnHeight >= 200.0)
    }
}
