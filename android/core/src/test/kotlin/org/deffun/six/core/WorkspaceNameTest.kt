package org.deffun.six.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Who named a workspace, and what that buys it — the port of the Mac's
 * `NiriLayoutWorkspaceNameTests`.
 *
 * niri's rule is that a named workspace survives running out of windows, and six kept it. What six
 * has that niri does not is programs that name workspaces: a research run names one after the
 * question it was asked, an agent asks for `workspace: "notes"` and gets one. Those names are labels
 * on a room that already exists, and when they outlived the room the rail filled up with empty rows
 * nobody had named. So a name a person typed holds the row open and a name a program made does not,
 * and this is the file that says the two fronts agree about it.
 */
class WorkspaceNameTest {

    private val viewport = Size(1600.0, 1000.0)
    private val profile: UUID = UUID.randomUUID()

    private fun layout(): NiriLayout =
        NiriLayout().updateViewport(viewport).setActiveProfile(profile).insertColumn(UUID.randomUUID())

    private fun names(layout: NiriLayout): List<String> = layout.workspaces.map { it.name }

    /**
     * The sequence every [NiriLayout.workspaceIndexNamed] caller performs: name a row, then put a
     * window in it. The row must still be there on the next line — the case that makes the rule a
     * transition rather than an invariant.
     */
    @Test
    fun aRowIsNotPrunedBetweenBeingNamedAndBeingFilled() {
        val (named, index) = layout().workspaceIndexNamed("tickets to KZ", profile, createIfMissing = true)
        assertEquals("tickets to KZ", named.workspaces[index!!].name)

        val document = UUID.randomUUID()
        val filled = named.insertColumn(document, profile, workspace = index)
        assertEquals(listOf(document), filled.workspaces[index].columns.map { it.tabId })
    }

    /** The pile this was written for: the run ends, its windows are closed, and the row goes too. */
    @Test
    fun aRowAProgramNamedGivesTheNameBackWhenItEmpties() {
        val (named, index) = layout().workspaceIndexNamed("research", profile, createIfMissing = true)
        val document = UUID.randomUUID()
        val filled = named.insertColumn(document, profile, workspace = index!!)
        assertTrue(names(filled).contains("research"))

        val emptied = filled.removeColumn(document)
        assertFalse(names(emptied).contains("research"))
        // And niri's dynamic workspaces still hold: the row with a window, and one empty one at the end.
        assertEquals(2, emptied.workspaces.size)
        assertTrue(emptied.workspaces.last().isEmpty)
    }

    /** The reservation, which is what naming a workspace is for. */
    @Test
    fun aRowAPersonNamedStaysWhenItEmpties() {
        val (named, index) = layout().workspaceIndexNamed("reading", profile, createIfMissing = true)
        val window = UUID.randomUUID()
        val emptied = named
            .insertColumn(window, profile, workspace = index!!)
            .focusWorkspaceAt(index)
            .renameWorkspace(index, "Reading") // typed into the plate: now it is a promise
            .removeColumn(window)

        assertTrue(names(emptied).contains("Reading"))
        assertTrue(emptied.workspaces.first { it.name == "Reading" }.isEmpty)
    }

    /**
     * What a snapshot written before the distinction comes back as. The rows look identical — a name
     * and no windows — so the one thing that can be said about them honestly is that nobody can now
     * say who named them.
     */
    @Test
    fun restoreDropsTheNamedRowsNobodyIsBehind() {
        val strip = NiriStrip(
            workspaces = listOf(
                NiriWorkspace(name = "research"),
                NiriWorkspace(name = "kept", namedByHand = true),
                NiriWorkspace(name = "working", columns = listOf(NiriColumn(UUID.randomUUID()))),
                NiriWorkspace(),
            ),
            focus = 2,
        )
        val restored = NiriLayout().updateViewport(viewport).setActiveProfile(profile)
            .restore(mapOf(profile to strip))

        assertEquals(listOf("kept", "working", ""), names(restored))
        // The focus followed the row it was on rather than the index it was at.
        assertEquals(1, restored.focusedWorkspaceIndex)
    }
}
