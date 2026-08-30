package org.deffun.six.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Which columns are live, which is a memory budget wearing geometry's clothes.
 *
 * On the Mac a `WebPage` is a content process and a strip of a hundred windows keeps only as many
 * as the machine can carry. Android has no process per tab, but a `WebView` is not cheap either, and
 * [NiriLayout.visibleTabIds] is what decides which columns get one — so it stopped being a drawing
 * detail the moment the strip started discarding.
 */
class VisibleTabsTest {

    private fun strip(columns: Int, viewport: Size = Size(1600.0, 1000.0)): Pair<NiriLayout, List<UUID>> {
        val ids = List(columns) { UUID.randomUUID() }
        var layout = NiriLayout().updateViewport(viewport)
        for (id in ids) layout = layout.insertColumn(id)
        return layout to ids
    }

    @Test
    fun aLongStripKeepsOnlyAFewColumnsLive() {
        val (layout, ids) = strip(columns = 100)

        val visible = layout.visibleTabIds
        assertTrue(visible.isNotEmpty(), "nothing is on screen")
        assertTrue(
            visible.size < 10,
            "a hundred columns left ${visible.size} live, which is not a budget",
        )
        assertContains(visible, ids.last(), "the focused column is not live")
    }

    /** Whatever else is true, the window being read has a page. */
    @Test
    fun theFocusedColumnIsAlwaysLive() {
        val (layout, ids) = strip(columns = 40)
        var current = layout
        for (index in listOf(0, 7, 20, 39)) {
            current = current.focus(ids[index])
            assertContains(
                current.visibleTabIds,
                ids[index],
                "column $index is focused and not live",
            )
        }
    }

    /**
     * The margin is half a screen on each side, so stepping to a neighbour finds its page already
     * built rather than watching it appear. Coming back is the case the whole design is tuned for.
     */
    @Test
    fun theNeighboursAreLiveBeforeTheyAreNeeded() {
        val (layout, ids) = strip(columns = 40)
        val current = layout.focus(ids[20])
        val visible = current.visibleTabIds

        assertContains(visible, ids[19], "the previous column is not warm")
        assertContains(visible, ids[21], "the next column is not warm")
        assertTrue(ids[0] !in visible, "a column twenty away is live")
        assertTrue(ids[39] !in visible, "a column nineteen away is live")
    }

    @Test
    fun anEmptyWorkspaceHasNothingLive() {
        assertEquals(emptySet(), NiriLayout().updateViewport(Size(1600.0, 1000.0)).visibleTabIds)
    }

    /**
     * Only the workspace on screen. Building a page for a workspace that is merely adjacent — during
     * a gesture that has not decided where it is going — is the worst possible moment to spend that.
     */
    @Test
    fun onlyTheFocusedWorkspaceIsLive() {
        val (layout, ids) = strip(columns = 3)
        val moved = layout.moveColumnToWorkspace(1)

        val visible = moved.visibleTabIds
        assertContains(visible, ids.last(), "the column that moved is where the focus went")
        assertTrue(
            ids.take(2).none { it in visible },
            "a workspace that is not on screen has live pages",
        )
    }

    /** A wider viewport shows more of the strip, and therefore keeps more of it live. */
    @Test
    fun aBiggerScreenCarriesMore() {
        val narrow = strip(columns = 60, viewport = Size(1000.0, 800.0)).first.visibleTabIds
        val wide = strip(columns = 60, viewport = Size(4000.0, 800.0)).first.visibleTabIds

        assertTrue(
            wide.size >= narrow.size,
            "a screen four times as wide keeps ${wide.size}, a narrow one ${narrow.size}",
        )
    }
}
