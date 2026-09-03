package org.deffun.six.core

import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * `state.json`, which is the second of the three artefacts Android shares with the Mac.
 *
 * The fixture is the shape of a file the Mac actually wrote — uppercase UUIDs, an absent `url` for a
 * document window, an Apple `Date` as a bare double, a window frame as nested arrays — with the
 * values replaced. It is not a recording of anyone's session and is not meant to be refreshed from
 * one; when the format changes, change it here deliberately.
 */
class AppStateSnapshotTest {

    private fun fixture(): String =
        checkNotNull(javaClass.getResourceAsStream("/state-fixture.json")) {
            "state-fixture.json is missing from the test resources"
        }.bufferedReader().readText()

    private fun decoded(): AppStateSnapshot =
        SnapshotJson.decodeFromString(AppStateSnapshot.serializer(), fixture())

    // MARK: What the Mac wrote, read here

    @Test
    fun readsAFileTheMacWrote() {
        val snapshot = decoded()

        assertEquals(1, snapshot.version)
        assertEquals(2, snapshot.browser.profiles.size)
        assertEquals("Personal", snapshot.browser.profiles[0].name)
        assertEquals("#4A90D9", snapshot.browser.profiles[0].colorHex)
        assertFalse(snapshot.browser.profiles[0].isPrivate)
        assertTrue(snapshot.browser.profiles[1].isPrivate)
        assertEquals(snapshot.browser.profiles[0].id, snapshot.browser.selectedProfileId)

        val strip = snapshot.browser.strips.single().strip
        assertEquals(2, strip.workspaces.size)
        assertEquals(2, strip.workspaces[0].columns.size)
        assertEquals(-85.55999999999995, strip.workspaces[0].viewOffset)
        // A named workspace with no columns: the one shape `normalize` must not prune.
        assertEquals("Reading", strip.workspaces[1].name)
        assertTrue(strip.workspaces[1].isEmpty)
    }

    /** Absent `url` is the start page. An empty string would be a page that fails to load. */
    @Test
    fun anAbsentUrlIsTheStartPageAndNotAnEmptyString() {
        val tabs = decoded().browser.tabs
        assertEquals("https://en.wikipedia.org/wiki/Pilaf", tabs[0].url)
        assertNull(tabs[1].url)
        assertNull(tabs[0].document)
    }

    /**
     * `Date` is seconds since 2001-01-01 UTC, not since the epoch. Read as Unix time this lands in
     * 1970 and sorts wrong without ever failing, which is why it is asserted against a real instant
     * rather than against itself.
     */
    @Test
    fun datesAreReadFromApplesReferenceDate() {
        val document = assertNotNull(decoded().browser.tabs[1].document)
        assertEquals(Instant.parse("2025-08-04T11:33:20.500Z"), document.modifiedAt)
    }

    // MARK: What Android carries without understanding

    /**
     * The agent branch, the research branch and the window frame belong to platforms this one is
     * not. Round-tripping them has to be exact: a field the Mac added and Android silently dropped
     * is a setting that disappears every time the phone is opened.
     */
    @Test
    fun theBranchesAndroidDoesNotModelSurviveARoundTrip() {
        val original = Json.parseToJsonElement(fixture()).jsonObject
        val snapshot = decoded()
        val written = Json.parseToJsonElement(
            SnapshotJson.encodeToString(AppStateSnapshot.serializer(), snapshot),
        ).jsonObject

        assertEquals(original["agent"], written["agent"], "the agent branch changed")
        assertEquals(original["window"], written["window"], "the window frame changed")
        assertEquals(
            original["browser"]!!.jsonObject["research"],
            written["browser"]!!.jsonObject["research"],
            "the research branch changed",
        )

        // And specifically the deep parts, which is where a dropped field would actually hide.
        val transcript = original["agent"]!!.jsonObject["chats"].toString()
        assertContains(written["agent"].toString(), "a shape Android does not model")
        assertContains(transcript, "sess_0001")
    }

    // MARK: What Android writes

    /**
     * `UUID.toString()` is lowercase in Java and uppercase through `Codable`. Nothing fails on a
     * lowercase id — both sides parse either — so the only place this is ever caught is here.
     */
    @Test
    fun uuidsAreWrittenUppercase() {
        val json = SnapshotJson.encodeToString(AppStateSnapshot.serializer(), decoded())

        assertContains(json, "1B7A55C0-0000-4A00-9E31-000000000001")
        assertFalse(
            json.contains("1b7a55c0-0000-4a00-9e31-000000000001"),
            "a lowercase UUID reached the file",
        )
    }

    /**
     * Every non-optional property is written, default-valued or not.
     *
     * Kotlin's instinct is to omit a value equal to its default; Swift's synthesised `init(from:)`
     * does not fall back to a default for a missing key, it throws `keyNotFound`. So omitting these
     * does not cost one field its default — it costs the Mac the whole file, at the next launch,
     * with no way back. The four below are every property in the snapshot that has a default and is
     * not an optional; adding a fifth without adding it here is the way this returns.
     */
    @Test
    fun defaultedPropertiesAreWrittenBecauseSwiftWillNotInferThem() {
        val json = SnapshotJson.encodeToString(AppStateSnapshot.serializer(), decoded())

        for (key in listOf("focus", "name", "columns", "isPrivate")) {
            assertContains(json, "\"$key\"", message = "the Mac's decoder requires `$key` and it was omitted")
        }
    }

    /** Swift omits a nil optional rather than writing `null`; so does this. */
    @Test
    fun absentValuesAreOmittedRatherThanWrittenAsNull() {
        val json = SnapshotJson.encodeToString(AppStateSnapshot.serializer(), decoded())
        assertFalse(json.contains("null"), "an explicit null reached the file")
    }

    @Test
    fun aSnapshotSurvivesTheRoundTripAsAValue() {
        val snapshot = decoded()
        val again = SnapshotJson.decodeFromString(
            AppStateSnapshot.serializer(),
            SnapshotJson.encodeToString(AppStateSnapshot.serializer(), snapshot),
        )
        assertEquals(snapshot, again)
    }

    // MARK: The file store

    @Test
    fun savingAndLoadingRoundTripsThroughAFile() {
        val directory = Files.createTempDirectory("six-snapshot").toFile()
        val store = FileSnapshotStore(File(directory, "nested/state.json"))

        assertNull(store.load(), "a store with no file should load nothing")

        val snapshot = decoded()
        store.save(snapshot)
        store.save(snapshot) // overwriting an existing file is the common case, not the first write

        assertEquals(snapshot, store.load())
        assertFalse(File(directory, "nested/state.json.new").exists(), "the temporary was left behind")

        directory.deleteRecursively()
    }

    /** An older build refuses a newer file instead of guessing at it. */
    @Test
    fun aNewerVersionIsRefusedRatherThanGuessedAt() {
        val directory = Files.createTempDirectory("six-snapshot").toFile()
        val file = File(directory, "state.json")
        file.writeText(fixture().replace("\"version\" : 1", "\"version\" : 99"))

        assertNull(FileSnapshotStore(file).load())

        directory.deleteRecursively()
    }

    /**
     * A strip read out of the file is a strip the layout can lay out — the two artefacts meet here,
     * and this is the one test that would catch them drifting apart.
     */
    @Test
    fun aRestoredStripLaysOut() {
        val snapshot = decoded()
        val restored = NiriLayout()
            .updateViewport(Size(1179.0, 2556.0))
            .copy(activeProfileId = snapshot.browser.selectedProfileId)
            .restore(snapshot.browser.strips.associate { it.profileId to it.strip })

        // Three, not two: `normalize` keeps the named-but-empty "Reading" — niri's rule that a name
        // outlives the last window — and then adds the trailing empty one every strip ends with.
        assertEquals(3, restored.workspaces.size)
        assertTrue(restored.workspaces.last().isEmpty && restored.workspaces.last().name.isEmpty())
        assertEquals("Reading", restored.workspaces[1].name)

        val focused = assertNotNull(restored.focusedWorkspace)
        assertEquals(2, focused.columns.size)
        assertEquals(2, restored.columnFrames(focused).size)
        assertNotNull(restored.focusedTabId)
        assertTrue(restored.visibleTabIds.isNotEmpty(), "nothing in the strip is on screen")
    }

    /** Empty in, empty out: a first launch has no file and must not need one. */
    @Test
    fun aMinimalSnapshotIsValid() {
        val id = UUID.randomUUID()
        val snapshot = AppStateSnapshot(
            browser = BrowserSnapshot(
                profiles = emptyList(),
                selectedProfileId = id,
                tabs = emptyList(),
                strips = emptyList(),
            ),
        )
        val json = SnapshotJson.encodeToString(AppStateSnapshot.serializer(), snapshot)
        val again = SnapshotJson.decodeFromString(AppStateSnapshot.serializer(), json)

        assertEquals(snapshot, again)
        assertEquals(emptyMap(), (Json.parseToJsonElement(json) as JsonObject).filterKeys { it == "agent" })
    }
}
