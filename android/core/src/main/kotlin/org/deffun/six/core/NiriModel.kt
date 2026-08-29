package org.deffun.six.core

import java.util.UUID

/** One window in the strip: a tab plus its niri-style sizing. */
data class NiriColumn(
    val tabId: UUID,
    val widthIndex: Int = NiriLayout.DEFAULT_WIDTH_INDEX,
)

/** A niri workspace: an infinite horizontal strip of full-height columns. */
data class NiriWorkspace(
    val id: UUID = UUID.randomUUID(),
    /** Optional, like niri's named workspaces. A named one survives running out of windows. */
    val name: String = "",
    val columns: List<NiriColumn> = emptyList(),
    /** Index of the focused column. */
    val focus: Int = 0,
    /** Scroll position of the strip, in points of content space. */
    val viewOffset: Double = 0.0,
) {
    val isEmpty: Boolean get() = columns.isEmpty()
    val focusedColumn: NiriColumn? get() = columns.getOrNull(focus)
}

/**
 * How much room the focused window is given. The widths in [NiriLayout.WIDTH_PRESETS] are the tiled
 * case; the other two step outside the tiling entirely, and the strip goes on working underneath both.
 */
enum class NiriFill {
    /** The strip as usual: gaps, title bars, and the width the column's preset asks for. */
    TILED,

    /**
     * The page fills the window under the top bar — no gaps, no title bar. The layout's own controls
     * stay where they are.
     */
    WINDOW,

    /** Fullscreen: the top bar goes too, and only the bar hiding at the top edge comes back. */
    SCREEN,
}

/** The vertical stack of workspaces belonging to one profile. */
data class NiriStrip(
    val workspaces: List<NiriWorkspace> = listOf(NiriWorkspace()),
    /** Index of the focused workspace. */
    val focus: Int = 0,
)
