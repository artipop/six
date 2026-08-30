package org.deffun.six.core

/**
 * Plain geometry, in `Double`.
 *
 * Compose has `androidx.compose.ui.geometry.Size` and `Rect` and the UI layer converts to them at
 * the boundary, but they are `Float` and this module is not. The strip's numbers have to agree with
 * a Mac computing them in `CGFloat`, so the arithmetic stays double-width all the way through and
 * loses precision only where it becomes a pixel.
 */
data class Size(val width: Double, val height: Double)

data class Rect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val maxX: Double get() = x + width
    val midX: Double get() = x + width / 2
    val minY: Double get() = y
    val maxY: Double get() = y + height
}
