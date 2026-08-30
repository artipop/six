package org.deffun.six.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What private browsing leaves behind, which has to be nothing.
 *
 * The promise is broken by omission rather than by error: a filter forgotten on one of three lists
 * writes a private session to disk, and nothing anywhere complains. So each of the three is a test,
 * and so is the one that is easier to miss — the selection.
 */
class PrivateBrowsingTest {

    private val work = Profile(UUID.randomUUID(), "Work", "#E8743B", UUID.randomUUID())
    private val privateProfile = Profile(
        id = UUID.randomUUID(),
        name = Profile.PRIVATE_NAME,
        colorHex = Profile.PRIVATE_COLOR_HEX,
        dataStoreId = UUID.randomUUID(),
        isPrivate = true,
    )

    private fun tab(profile: Profile) = TabSnapshot(UUID.randomUUID(), profile.id, "https://example.org")

    private fun snapshot(selected: UUID) = buildBrowserSnapshot(
        profiles = listOf(work, privateProfile),
        selectedProfileId = selected,
        tabs = listOf(tab(work), tab(privateProfile), tab(privateProfile)),
        strips = listOf(
            StripSnapshot(work.id, NiriStrip()),
            StripSnapshot(privateProfile.id, NiriStrip()),
        ),
    )

    /** The Mac's literals. Two front ends inventing two names for this is two profiles. */
    @Test
    fun thePrivateProfileIsTheOneTheMacWouldHaveMade() {
        assertEquals("Private", Profile.PRIVATE_NAME)
        assertEquals("#5C5C66", Profile.PRIVATE_COLOR_HEX)
    }

    @Test
    fun neitherTheProfileNorItsWindowsNorItsStripReachTheFile() {
        val snapshot = snapshot(selected = work.id)

        assertEquals(listOf(work), snapshot.profiles)
        assertEquals(listOf(work.id), snapshot.tabs.map { it.profileId })
        assertEquals(listOf(work.id), snapshot.strips.map { it.profileId })
    }

    /** Saving "the profile on screen" would restore into a profile that is not in the file. */
    @Test
    fun theSelectionFallsBackToAProfileThatIsActuallyThere() {
        val snapshot = snapshot(selected = privateProfile.id)

        assertEquals(work.id, snapshot.selectedProfileId)
        assertTrue(snapshot.profiles.any { it.id == snapshot.selectedProfileId })
    }

    /** A public selection is left alone. */
    @Test
    fun anOrdinarySelectionIsNotDisturbed() {
        assertEquals(work.id, snapshot(selected = work.id).selectedProfileId)
    }

    /**
     * Written and read back: what comes out has never heard of the private profile.
     *
     * Read back rather than grepped. The obvious version of this test looks for the word "Private"
     * in the JSON and passes for the wrong reason forever, because `"isPrivate": false` contains it.
     */
    @Test
    fun whatIsWrittenHasNoTraceOfIt() {
        val written = SnapshotJson.encodeToString(
            AppStateSnapshot.serializer(),
            AppStateSnapshot(browser = snapshot(selected = privateProfile.id)),
        )
        val read = SnapshotJson.decodeFromString(AppStateSnapshot.serializer(), written).browser

        assertTrue(read.profiles.none { it.isPrivate }, "a private profile was written")
        assertTrue(read.profiles.none { it.id == privateProfile.id }, "its id was written")
        assertTrue(read.tabs.none { it.profileId == privateProfile.id }, "its windows were written")
        assertTrue(read.strips.none { it.profileId == privateProfile.id }, "its strip was written")
        assertTrue(!written.contains(privateProfile.id.toString().uppercase()), "its id leaked somewhere")
    }

    /** The other half: answers given inside a private profile never reach the settings table. */
    @Test
    fun itsPermissionAnswersAreNotWrittenEither() {
        var saved: List<PermissionDecision>? = null
        val permissions = SitePermissions(onSave = { saved = it })
        permissions.isPrivate = { it == privateProfile.id }

        permissions.set(true, SitePermission.CAMERA, "https://example.org", privateProfile.id)
        permissions.set(true, SitePermission.CAMERA, "https://example.org", work.id)

        // Answered, for as long as the profile lives.
        assertEquals(true, permissions.decision(SitePermission.CAMERA, "https://example.org", privateProfile.id))
        // And absent from what was written.
        assertEquals(listOf(work.id), saved?.map { it.profileId })
    }

    /** And the third: nothing it visited is in the history the Mac reads. */
    @Test
    fun aPrivateProfileHasNoHistoryToShare() {
        // The rule itself is the caller's — `HistoryStore` records whatever it is handed — so what is
        // pinned here is that a profile can be recognised as private at the point where it matters.
        assertTrue(privateProfile.isPrivate)
        assertTrue(!work.isPrivate)
    }
}
