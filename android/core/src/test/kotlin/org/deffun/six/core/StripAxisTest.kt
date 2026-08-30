package org.deffun.six.core

import java.util.UUID
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The axis, which is the one piece of the layout that is genuinely the view's business.
 *
 * Worth testing away from the UI precisely because it is a UI concern: getting it wrong produces a
 * strip that works perfectly and runs the wrong way, which no assertion about `NiriLayout` would
 * ever notice.
 */
class StripAxisTest {

    private val phonePortrait = Size(1179.0, 2556.0)
    private val phoneLandscape = Size(2556.0, 1179.0)
    private val tabletPortrait = Size(1024.0, 1366.0)
    private val tabletLandscape = Size(1366.0, 1024.0)

    @Test
    fun theAxisFollowsTheShapeAndNotTheSize() {
        assertEquals(Along.Y, Along.of(phonePortrait))
        assertEquals(Along.X, Along.of(phoneLandscape))
        // The half a size class would get wrong: a tablet is "large" held either way.
        assertEquals(Along.Y, Along.of(tabletPortrait))
        assertEquals(Along.X, Along.of(tabletLandscape))
    }

    /** `>` and not `>=`, matching the Mac, so the one meaningless shape is meaningless identically. */
    @Test
    fun aSquareViewportRunsAlongX() {
        assertEquals(Along.X, Along.of(Size(1000.0, 1000.0)))
    }

    /** The strip is always handed its long edge first, whatever the device is doing. */
    @Test
    fun stripSpacePutsTheAlongExtentFirst() {
        for (viewport in listOf(phonePortrait, phoneLandscape, tabletPortrait, tabletLandscape)) {
            val strip = StripAxis.of(viewport).stripSpace(viewport)
            assertTrue(
                strip.width >= strip.height,
                "$viewport became $strip, which is not along-first",
            )
            assertEquals(
                viewport.width * viewport.height,
                strip.width * strip.height,
                "$viewport changed area on the way into strip space",
            )
        }
    }

    @Test
    fun screenSpaceUndoesStripSpace() {
        for (viewport in listOf(phonePortrait, phoneLandscape, tabletPortrait)) {
            val axis = StripAxis.of(viewport)
            assertEquals(viewport, axis.screenSpace(axis.stripSpace(viewport)))
        }
    }

    /**
     * Turning the device re-measures and re-centres, and nothing in the model moves: the same strip
     * at the same focus produces the same *along*-extents, drawn down the screen instead of across.
     */
    @Test
    fun turningTheDeviceDrawsTheSameStripDownTheScreen() {
        val workspace = NiriWorkspace(
            columns = listOf(0, 2, 3).map { NiriColumn(UUID.randomUUID(), it) },
        )

        val landscape = NiriLayout()
            .updateViewport(StripAxis.of(phoneLandscape).stripSpace(phoneLandscape))
        val portrait = NiriLayout()
            .updateViewport(StripAxis.of(phonePortrait).stripSpace(phonePortrait))

        // Same physical screen, turned: the strip's own space is identical, so the frames are too.
        assertEquals(landscape.viewport, portrait.viewport)
        assertEquals(landscape.columnFrames(workspace), portrait.columnFrames(workspace))

        val frame = portrait.columnFrames(workspace).first()
        val onScreen = StripAxis.of(phonePortrait).screenRect(frame)

        // Upright, a column's along-extent is its height on screen and its across-extent its width.
        assertEquals(frame.width, onScreen.height)
        assertEquals(frame.height, onScreen.width)
        assertEquals(frame.x, onScreen.y)
        assertEquals(frame.y, onScreen.x)
    }

    /** Laid out on screen, a column still fits the screen it was laid out for. */
    @Test
    fun everyColumnLandsInsideTheViewportItWasMeasuredFor() {
        for (viewport in listOf(phonePortrait, phoneLandscape, tabletPortrait, tabletLandscape)) {
            val axis = StripAxis.of(viewport)
            val layout = NiriLayout().updateViewport(axis.stripSpace(viewport))
            val workspace = NiriWorkspace(
                columns = List(4) { NiriColumn(UUID.randomUUID(), it % NiriLayout.WIDTH_PRESETS.size) },
            )

            for (frame in layout.columnFrames(workspace).map { axis.screenRect(it) }) {
                assertTrue(
                    frame.height <= viewport.height + 0.5 && frame.width <= viewport.width + 0.5,
                    "a column of ${frame.width}×${frame.height} does not fit $viewport",
                )
                // Across the strip, a column is inset by the outer gap at both edges.
                val across = if (axis.along == Along.X) frame.height else frame.width
                val acrossViewport = if (axis.along == Along.X) viewport.height else viewport.width
                assertTrue(
                    abs(across - (acrossViewport - 2 * layout.outerGap)) < 0.5,
                    "a column is $across across, expected ${acrossViewport - 2 * layout.outerGap}",
                )
            }
        }
    }

    /**
     * A drag down in portrait is a drag right on the Mac. Both arrive as a positive along-component,
     * which is what lets one set of gesture handling drive both.
     */
    @Test
    fun aDragResolvesIntoTheStripsOwnDirections() {
        val sideways = StripAxis(Along.X).stripDelta(dx = 12.0, dy = -3.0)
        assertEquals(StripDelta(along = 12.0, across = -3.0), sideways)

        val upright = StripAxis(Along.Y).stripDelta(dx = -3.0, dy = 12.0)
        assertEquals(StripDelta(along = 12.0, across = -3.0), upright)
    }
}
