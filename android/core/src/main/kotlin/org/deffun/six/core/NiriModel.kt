package org.deffun.six.core

import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * One window in the strip: a tab plus its niri-style sizing.
 *
 * `tabID` rather than `tabId`: the key is the Mac's, and `state.json` is a shared file rather than
 * this module's own format.
 */
@Serializable
data class NiriColumn(
    @Serializable(with = UuidSerializer::class)
    @SerialName("tabID")
    val tabId: UUID,
)

/** A niri workspace: an infinite horizontal strip of full-height columns. */
@Serializable
data class NiriWorkspace(
    @Serializable(with = UuidSerializer::class)
    val id: UUID = UUID.randomUUID(),
    /**
     * Optional, like niri's named workspaces. A named one survives running out of windows — if a
     * person is behind the name.
     */
    val name: String = "",
    val columns: List<NiriColumn> = emptyList(),
    /** Index of the focused column. */
    val focus: Int = 0,
    /** Scroll position of the strip, in points of content space. */
    val viewOffset: Double = 0.0,
    /**
     * Whether a person typed that name. A name typed into the plate is a reservation: it holds the
     * row open before there is anything in it, which is the whole point of naming one. A name a
     * program made up — the question a research run started with, an agent's `workspace: "notes"` —
     * is a label on a room that already existed, and it must not outlive the room.
     *
     * Absent in files from before the distinction, and read as *not* a reservation.
     */
    val namedByHand: Boolean? = null,
    // Last in the list, so that every positional `NiriWorkspace(...)` keeps its meaning.
) {
    val isEmpty: Boolean get() = columns.isEmpty()
    val focusedColumn: NiriColumn? get() = columns.getOrNull(focus)
}

/**
 * How much room the focused window is given, and the whole of what there is to choose. A window is a
 * screen's worth of page in all three: the strip leaves it the gaps it needs to read as a card in a
 * row of them, the other two take even those away. There is deliberately nothing smaller.
 */
enum class NiriFill {
    /** The strip as usual: the gaps, and a window as wide as the screen leaves room for. */
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
@Serializable
data class NiriStrip(
    val workspaces: List<NiriWorkspace> = listOf(NiriWorkspace()),
    /** Index of the focused workspace. */
    val focus: Int = 0,
)
