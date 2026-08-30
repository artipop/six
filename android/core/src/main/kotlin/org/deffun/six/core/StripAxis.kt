package org.deffun.six.core

/**
 * Which way round the strip runs on this screen.
 *
 * The niri model is one-dimensional: columns follow one another *along* the strip, workspaces stack
 * *across* it. Which screen direction that is belongs to the view, not to the model, so
 * [NiriLayout] never learns the answer — it is handed a viewport along-first and gives back extents
 * in the same terms.
 *
 * | | along the strip | across it |
 * |---|---|---|
 * | a device on its side | left → right | up / down |
 * | a device held upright | top → bottom | left / right |
 *
 * ## Why the shape and not the size class
 *
 * The strip wants the screen's long edge to run along it, so the axis is the viewport's own
 * proportions and nothing else. The Android instinct here is a `sw600dp` resource qualifier, which
 * answers a different question and answers it the same way in both orientations — a tablet is
 * "large" whichever way it is held, which would leave it laid out sideways upright. iPadOS size
 * classes make exactly the same mistake, which is why the Mac's rule is `size.height > size.width`
 * and this one is too.
 *
 * A square viewport is [Along.X]: `>` rather than `>=`, matching the Mac, so that the one shape
 * where "long edge" means nothing at least means the same thing on both.
 */
enum class Along {
    /** A device on its side: columns run left to right, workspaces stack up and down. */
    X,

    /** A device held upright: columns run top to bottom, workspaces stack left and right. */
    Y,
    ;

    companion object {
        fun of(viewport: Size): Along = if (viewport.height > viewport.width) Y else X
    }
}

/**
 * The mapping between the strip's own coordinates and the screen's.
 *
 * "Strip space" is always along-first: x runs along the strip and y across it, whatever the device
 * is doing. Everything [NiriLayout] computes — widths, gaps, offsets, `columnFrames` — is in that
 * space, and this is the only place that knows which way it points.
 */
data class StripAxis(val along: Along) {

    companion object {
        fun of(viewport: Size): StripAxis = StripAxis(Along.of(viewport))
    }

    /** The viewport as [NiriLayout.updateViewport] wants it: the along-extent first. */
    fun stripSpace(viewport: Size): Size = when (along) {
        Along.X -> viewport
        Along.Y -> Size(viewport.height, viewport.width)
    }

    /** And back, for anything that has to be handed a real screen size again. */
    fun screenSpace(strip: Size): Size = when (along) {
        Along.X -> strip
        Along.Y -> Size(strip.height, strip.width)
    }

    /** A rectangle from `columnFrames`, placed on the screen. */
    fun screenRect(frame: Rect): Rect = when (along) {
        Along.X -> frame
        Along.Y -> Rect(x = frame.y, y = frame.x, width = frame.height, height = frame.width)
    }

    /**
     * A drag, in screen pixels, as the strip reads it.
     *
     * The sign is the reason this is a function rather than a swap. Dragging a finger *down* in
     * portrait walks the strip the way dragging *right* does on the Mac, so both come back as a
     * positive along-component and `NiriLayout` never has to know which happened.
     */
    fun stripDelta(dx: Double, dy: Double): StripDelta = when (along) {
        Along.X -> StripDelta(along = dx, across = dy)
        Along.Y -> StripDelta(along = dy, across = dx)
    }
}

/** A gesture, resolved into the strip's two directions. */
data class StripDelta(val along: Double, val across: Double)

/** What letting go of a drag should do. */
enum class StripStep {
    NONE,
    PREVIOUS_COLUMN,
    NEXT_COLUMN,
    PREVIOUS_WORKSPACE,
    NEXT_WORKSPACE,
}

/**
 * The rubber band, read.
 *
 * ## The convention this depends on
 *
 * Content is drawn *plus* the band on both axes — columns at `frame.x - (offset - horizontalPreview)`
 * and workspaces at `offset * step + verticalPreview` — so content follows the finger, and a
 * positive band therefore reveals what comes **before**. Everything below is that sentence turned
 * into steps, and `StripAxisTest` asserts the drawing and the stepping still agree, because a sign
 * flipped in one of the two places is a gesture that shows one thing and commits its opposite.
 *
 * Across the strip wins over along when a drag was both: workspaces are the coarser move, and a
 * diagonal that changes both at once is never what was meant.
 */
val NiriLayout.pendingStep: StripStep
    get() {
        val alongThreshold = viewport.width * NiriLayout.DRAG_COMMIT_FRACTION
        val acrossThreshold = viewport.height * NiriLayout.DRAG_COMMIT_FRACTION
        return when {
            verticalPreview > acrossThreshold -> StripStep.PREVIOUS_WORKSPACE
            verticalPreview < -acrossThreshold -> StripStep.NEXT_WORKSPACE
            horizontalPreview > alongThreshold -> StripStep.PREVIOUS_COLUMN
            horizontalPreview < -alongThreshold -> StripStep.NEXT_COLUMN
            else -> StripStep.NONE
        }
    }

/** Letting go either commits a step or springs back; nothing rests half-way. */
fun NiriLayout.releaseDrag(): NiriLayout {
    val stepped = when (pendingStep) {
        StripStep.NONE -> this
        StripStep.PREVIOUS_COLUMN -> focusColumn(-1)
        StripStep.NEXT_COLUMN -> focusColumn(1)
        StripStep.PREVIOUS_WORKSPACE -> focusWorkspace(-1)
        StripStep.NEXT_WORKSPACE -> focusWorkspace(1)
    }
    return stepped.copy(horizontalPreview = 0.0, verticalPreview = 0.0)
}
