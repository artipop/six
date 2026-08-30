package org.deffun.six.core

import java.util.UUID
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * What a drag shows, and what letting go of it does — which have to be the same direction.
 *
 * These two live in different places: the drawing is in the Compose layer and the stepping is here.
 * A sign flipped in one of them is a gesture that reveals one thing and commits its opposite, and
 * nothing about either half looks wrong on its own. So the drawing convention is restated as an
 * assertion rather than as a comment.
 */
class DragTest {

    private val viewport = Size(1600.0, 1000.0)

    private fun strip(columns: Int = 5, workspaces: Int = 1): Pair<NiriLayout, List<UUID>> {
        val ids = List(columns) { UUID.randomUUID() }
        var layout = NiriLayout().updateViewport(viewport)
        for (id in ids) layout = layout.insertColumn(id)
        repeat(workspaces - 1) { layout = layout.moveColumnToWorkspace(1).focusWorkspace(-1) }
        return layout to ids
    }

    // MARK: Where the finger takes it

    /**
     * The drawing convention, asserted: columns are placed at `frame.x - (offset - band)`, so a
     * positive band moves content the way the finger went and brings the *previous* column towards
     * the middle of the screen. `pendingStep` has to read it the same way.
     */
    @Test
    fun aPositiveBandRevealsWhatComesBefore() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])
        val workspace = requireNotNull(focused.focusedWorkspace)
        val frames = focused.columnFrames(workspace)
        val centre = focused.visibleWidth / 2

        fun distanceOfPreviousColumn(band: Double): Double {
            val banded = focused.copy(horizontalPreview = band)
            val scroll = banded.resolvedOffset(workspace) - band
            return abs(frames[1].midX - scroll - centre)
        }

        assertTrue(
            distanceOfPreviousColumn(200.0) < distanceOfPreviousColumn(0.0),
            "a positive band does not bring the previous column closer",
        )
        assertEquals(StripStep.PREVIOUS_COLUMN, focused.copy(horizontalPreview = 400.0).pendingStep)
    }

    @Test
    fun aNegativeBandRevealsWhatComesAfter() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])
        assertEquals(StripStep.NEXT_COLUMN, focused.copy(horizontalPreview = -400.0).pendingStep)
    }

    /**
     * Across the strip, the same sentence: workspaces are drawn at `offset * step + band`, so a
     * positive band slides the stack the way the finger went and reveals the one before.
     */
    @Test
    fun theAcrossBandReadsTheSameWayRound() {
        val (layout, _) = strip()
        assertEquals(StripStep.PREVIOUS_WORKSPACE, layout.copy(verticalPreview = 400.0).pendingStep)
        assertEquals(StripStep.NEXT_WORKSPACE, layout.copy(verticalPreview = -400.0).pendingStep)
    }

    // MARK: Committing

    @Test
    fun aBandBelowTheThresholdSpringsBack() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])
        val nudged = focused.copy(horizontalPreview = viewport.width * 0.05)

        assertEquals(StripStep.NONE, nudged.pendingStep)

        val released = nudged.releaseDrag()
        assertEquals(focused.focusedTabId, released.focusedTabId, "a nudge changed the focus")
        assertEquals(0.0, released.horizontalPreview)
        assertEquals(0.0, released.verticalPreview)
    }

    @Test
    fun lettingGoNeverRestsHalfWay() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])

        for (band in listOf(0.0, 100.0, -100.0, 900.0, -900.0)) {
            val released = focused.copy(horizontalPreview = band, verticalPreview = band).releaseDrag()
            assertEquals(0.0, released.horizontalPreview, "band $band left a horizontal remainder")
            assertEquals(0.0, released.verticalPreview, "band $band left a vertical remainder")
        }
    }

    @Test
    fun aCommittedDragStepsTheFocus() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])

        assertEquals(
            ids[1],
            focused.copy(horizontalPreview = 400.0).releaseDrag().focusedTabId,
        )
        assertEquals(
            ids[3],
            focused.copy(horizontalPreview = -400.0).releaseDrag().focusedTabId,
        )
    }

    /**
     * The dominant direction decides, which is the iPhone's rule and not a precedence between the
     * two. A hand that is not quite straight should still walk the strip.
     */
    @Test
    fun theLargerComponentWinsOutright() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])

        // Along dominant, across still over its own threshold: this is a column move.
        assertEquals(
            StripStep.NEXT_COLUMN,
            focused.copy(horizontalPreview = -500.0, verticalPreview = -300.0).pendingStep,
        )
        // And the other way round.
        assertEquals(
            StripStep.NEXT_WORKSPACE,
            focused.copy(horizontalPreview = -300.0, verticalPreview = -500.0).pendingStep,
        )
    }

    /** A tie goes across, because that is the coarser move. */
    @Test
    fun aDiagonalIsAWorkspaceMoveAndNotBoth() {
        val (layout, ids) = strip(columns = 5)
        val focused = layout.focus(ids[2])
        val diagonal = focused.copy(horizontalPreview = -400.0, verticalPreview = -400.0)

        assertEquals(StripStep.NEXT_WORKSPACE, diagonal.pendingStep)

        val released = diagonal.releaseDrag()
        assertNotEquals(
            focused.focusedWorkspaceIndex,
            released.focusedWorkspaceIndex,
            "the workspace did not change",
        )
    }

    /** The threshold is the iPhone's 0.12 of the viewport, not a number invented here. */
    @Test
    fun theThresholdIsTheOneThePhoneUses() {
        assertEquals(0.12, NiriLayout.DRAG_COMMIT_FRACTION)
    }

    /** The threshold scales with the screen, for the same reason the gaps do. */
    @Test
    fun theThresholdIsAFractionOfTheViewport() {
        val small = NiriLayout().updateViewport(Size(400.0, 300.0))
        val large = NiriLayout().updateViewport(Size(4000.0, 3000.0))
        val band = 400.0 * NiriLayout.DRAG_COMMIT_FRACTION + 1

        assertEquals(StripStep.PREVIOUS_COLUMN, small.copy(horizontalPreview = band).pendingStep)
        assertEquals(StripStep.NONE, large.copy(horizontalPreview = band).pendingStep)
    }

    /** Stepping past the end of the strip is a spring-back, not an error and not a wrap. */
    @Test
    fun steppingPastTheEndStaysWhereItIs() {
        val (layout, ids) = strip(columns = 3)
        val last = layout.focus(ids.last())
        val released = last.copy(horizontalPreview = -900.0).releaseDrag()

        assertEquals(ids.last(), released.focusedTabId)
    }
}
