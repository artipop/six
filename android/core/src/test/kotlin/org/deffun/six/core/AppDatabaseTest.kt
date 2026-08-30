package org.deffun.six.core

import androidx.sqlite.execSQL
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `six.sqlite`, the third of the three shared artefacts.
 *
 * Everything here is about being the *second* writer of a file GRDB defines. The schema assertions
 * are transcribed from the real database's `.schema`, so a migration edited on one side and not the
 * other shows up as a failure rather than as a table that quietly gains a column on one platform.
 */
class AppDatabaseTest {

    private val directory: File = Files.createTempDirectory("six-db").toFile()
    private fun open(name: String = AppDatabase.FILE_NAME) =
        AppDatabase.open(File(directory, name))

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
    }

    // MARK: Migrations

    /**
     * The identifiers are GRDB's strings, character for character. If Android records a different
     * one, GRDB runs its own copy of the same migration on the next launch, its `CREATE TABLE` hits
     * a table that already exists, and the Mac does not start.
     */
    @Test
    fun theMigrationIdentifiersAreTheMacs() {
        assertEquals(
            listOf(
                "v1 visits, settings",
                "v2 bookmarks",
                "v3 bookmark refresh",
                "v4 vectors in vec0",
            ),
            AppDatabase.MIGRATIONS.map { it.identifier },
        )
    }

    @Test
    fun openingAFreshFileRecordsEveryMigration() {
        open().use { database ->
            assertEquals(
                AppDatabase.MIGRATIONS.map { it.identifier }.toSet(),
                database.appliedMigrations(),
            )
        }
    }

    /** Migrations are named, not numbered: `user_version` is 0 in a real six database. */
    @Test
    fun migrationsAreTrackedByNameAndNotByUserVersion() {
        open().use { database ->
            database.prepare("PRAGMA user_version") {
                assertTrue(it.step())
                assertEquals(0L, it.getLong(0))
            }
        }
    }

    @Test
    fun openingTwiceDoesNotRunAnythingASecondTime() {
        val file = File(directory, AppDatabase.FILE_NAME)
        AppDatabase.open(file).close()
        // A re-run of `v1` would fail on `CREATE TABLE "visits"`, so surviving this is the assertion.
        AppDatabase.open(file).use { database ->
            assertEquals(AppDatabase.MIGRATIONS.size, database.appliedMigrations().size)
        }
    }

    /**
     * A file carrying identifiers this build has never heard of was written by a newer Mac. That is
     * not an error and not something to repair: the tables Android reads are still there.
     */
    @Test
    fun aNewerMacsMigrationsAreLeftAlone() {
        val file = File(directory, AppDatabase.FILE_NAME)
        AppDatabase.open(file).use { database ->
            database.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)") {
                it.bindText(1, "v9 something Android has never seen")
                it.step()
            }
        }

        AppDatabase.open(file).use { database ->
            assertContains(database.appliedMigrations(), "v9 something Android has never seen")
            assertEquals(AppDatabase.MIGRATIONS.size + 1, database.appliedMigrations().size)
        }
    }

    /** v2 creates `bookmark_vectors` and v4 drops it. Replaying that history differently diverges. */
    @Test
    fun theSupersededVectorTableIsCreatedAndThenDropped() {
        open().use { database ->
            assertFalse(database.hasTable("bookmark_vectors"), "v4 did not drop what v2 made")
            for (table in listOf("visits", "settings", "bookmarks", "bookmark_chunks")) {
                assertTrue(database.hasTable(table), "$table is missing")
            }
        }
    }

    // MARK: The schema itself

    /**
     * Transcribed from the real file's `.schema`. Column *order* matters as much as the names here:
     * `ALTER TABLE ADD COLUMN` appends, so v3's three columns come last, and a build that created
     * them inline in v2 would produce a table that is the same to a human and different to anything
     * comparing schemas.
     */
    @Test
    fun theTablesHaveTheMacsColumnsInTheMacsOrder() {
        open().use { database ->
            assertEquals(
                listOf("id", "profileID", "url", "title", "visitedAt"),
                database.columns("visits"),
            )
            assertEquals(listOf("key", "value"), database.columns("settings"))
            assertEquals(
                listOf("id", "bookmarkID", "ord", "text"),
                database.columns("bookmark_chunks"),
            )
            assertEquals(
                listOf(
                    "id", "profileID", "url", "title", "excerpt", "siteName", "imageURL",
                    "fileName", "language", "characterCount", "createdAt", "indexedAt",
                    "embeddingModel", "indexError",
                    // v3, appended by ALTER TABLE — last, and in this order.
                    "refreshedAt", "contentHash", "refreshError",
                ),
                database.columns("bookmarks"),
            )
        }
    }

    /**
     * STRICT is part of the schema, and it is what makes a wrong type an error instead of a row.
     *
     * Not as strict as the name suggests, which is worth pinning down rather than assuming: STRICT
     * still performs a conversion that is lossless and reversible, so a REAL goes into a TEXT column
     * happily as `'5.5'`. What it refuses is a conversion that would lose something — text into an
     * INTEGER column, a BLOB into a TEXT one. Only the second kind is a guarantee to rely on.
     */
    @Test
    fun theTablesAreStrict() {
        open().use { database ->
            assertFailsWith<Throwable>("STRICT allowed text in an INTEGER column") {
                database.execute(
                    """INSERT INTO "bookmark_chunks" ("id", "bookmarkID", "ord", "text") VALUES ('a','b','not a number','t')""",
                )
            }
            assertFailsWith<Throwable>("STRICT allowed a BLOB in a TEXT column") {
                database.execute(
                    """INSERT INTO "bookmark_chunks" ("id", "bookmarkID", "ord", "text") VALUES ('a','b',0,x'00')""",
                )
            }
            // And the conversion it does allow, so the boundary is documented by the test rather
            // than by the next person's surprise.
            database.execute(
                """INSERT INTO "bookmark_chunks" ("id", "bookmarkID", "ord", "text") VALUES ('a','b',0,5.5)""",
            )
            database.prepare("""SELECT "text" FROM "bookmark_chunks" WHERE "id" = 'a'""") {
                assertTrue(it.step())
                assertEquals("5.5", it.getText(0))
            }
        }
    }

    // MARK: Values

    /**
     * UUIDs are lowercase here and uppercase in `state.json`, and SQLite compares text with BINARY
     * collation. A `profileID` written in the wrong case matches nothing and reports nothing: the
     * profile just has no history, on a database full of it.
     */
    @Test
    fun uuidsAreStoredLowercaseSoTheMacsRowsMatch() {
        val profile = UUID.fromString("ED2FCED9-98A6-4F1A-B360-3BD6D9887847")
        open().use { database ->
            val history = HistoryStore(database)
            history.record("https://example.org/", "Example", profile)

            database.prepare("""SELECT "profileID" FROM "visits" LIMIT 1""") {
                assertTrue(it.step())
                assertEquals("ed2fced9-98a6-4f1a-b360-3bd6d9887847", it.getText(0))
            }
            // The half that actually bites. `UUID.toString()` is already lowercase in Java, so the
            // uppercase form only ever arrives by hand — from someone reaching for the convention
            // `state.json` uses. It matches nothing, and says nothing about why.
            database.prepare("""SELECT count(*) FROM "visits" WHERE "profileID" = ?""") {
                it.bindText(1, profile.toString().uppercase())
                assertTrue(it.step())
                assertEquals(0L, it.getLong(0), "SQLite text comparison stopped being case-sensitive")
            }
            assertEquals(1, history.entries(profile).size)
        }
    }

    /**
     * Dates are UTC text with no zone marker. Read as local time they shift by the machine's offset,
     * which reorders history without failing.
     */
    @Test
    fun datesAreWrittenAsGrdbsUtcText() {
        val moment = Instant.parse("2026-08-29T05:39:33.127Z")
        assertEquals("2026-08-29 05:39:33.127", GrdbDate.format(moment))
        assertEquals(moment, GrdbDate.parse("2026-08-29 05:39:33.127"))
        // GRDB writes these shapes too, and a file that has been through more than one version has them.
        assertEquals(Instant.parse("2026-08-29T05:39:33Z"), GrdbDate.parse("2026-08-29 05:39:33"))
        assertEquals(Instant.parse("2026-08-29T00:00:00Z"), GrdbDate.parse("2026-08-29"))
    }

    // MARK: History behaviour

    /** Revisiting the page you are already on refreshes the last visit rather than stacking one. */
    @Test
    fun revisitingTheSamePageUpdatesRatherThanStacks() {
        val profile = UUID.randomUUID()
        open().use { database ->
            val history = HistoryStore(database)
            val first = assertNotNull(
                history.record("https://example.org/", "Example", profile, Instant.parse("2026-08-29T10:00:00Z")),
            )
            val again = assertNotNull(
                history.record("https://example.org/", "", profile, Instant.parse("2026-08-29T10:05:00Z")),
            )

            assertEquals(first.id, again.id, "a second row was written for the same page")
            assertEquals(1, history.entries(profile).size)
            assertEquals("Example", history.entries(profile).single().title, "an empty title erased one")
            assertEquals(Instant.parse("2026-08-29T10:05:00Z"), history.entries(profile).single().visitedAt)
        }
    }

    @Test
    fun aDifferentPageIsANewVisitAndTheNewestComesFirst() {
        val profile = UUID.randomUUID()
        open().use { database ->
            val history = HistoryStore(database)
            history.record("https://example.org/one", "One", profile, Instant.parse("2026-08-29T10:00:00Z"))
            history.record("https://example.org/two", "Two", profile, Instant.parse("2026-08-29T10:01:00Z"))

            assertEquals(listOf("Two", "One"), history.entries(profile).map { it.title })
            assertEquals(1, history.entries(profile, limit = 1).size)
        }
    }

    @Test
    fun aTitleArrivingLateUpdatesTheNewestVisitOfThatPage() {
        val profile = UUID.randomUUID()
        open().use { database ->
            val history = HistoryStore(database)
            history.record("https://example.org/", "", profile, Instant.parse("2026-08-29T10:00:00Z"))
            history.updateTitle("Arrived later", "https://example.org/", profile)

            assertEquals("Arrived later", history.entries(profile).single().title)
        }
    }

    @Test
    fun historyIsPerProfileAndClearsPerProfile() {
        val mine = UUID.randomUUID()
        val theirs = UUID.randomUUID()
        open().use { database ->
            val history = HistoryStore(database)
            history.record("https://example.org/a", "A", mine)
            history.record("https://example.org/b", "B", theirs)

            history.clear(mine)

            assertTrue(history.entries(mine).isEmpty())
            assertEquals(1, history.entries(theirs).size)
        }
    }

    /** `six://start` and `about:blank` are not history, on either platform. */
    @Test
    fun onlyHttpHttpsAndFileAreRecordable() {
        for (url in listOf("https://example.org", "http://example.org", "file:///tmp/x.html")) {
            assertTrue(HistoryStore.isRecordable(url), url)
        }
        for (url in listOf("about:blank", "six://start", "data:text/html,x", "", "javascript:0")) {
            assertFalse(HistoryStore.isRecordable(url), url)
        }
        val profile = UUID.randomUUID()
        open().use { database ->
            val history = HistoryStore(database)
            assertNull(history.record("about:blank", "Blank", profile))
            assertTrue(history.entries(profile).isEmpty())
        }
    }

    // MARK: Settings

    @Test
    fun settingsAreKeysAndStringsAndTheKeyIsAnUpsert() {
        open().use { database ->
            val settings = SettingsStore(database)
            assertNull(settings["assistant.model"])

            settings["assistant.model"] = "onDevice"
            settings["assistant.model"] = "claudeSonnet"
            settings["layout.centersFocus"] = "true"

            assertEquals("claudeSonnet", settings["assistant.model"])
            assertEquals(2, settings.all().size)

            settings.remove("assistant.model")
            assertNull(settings["assistant.model"])
        }
    }

    /**
     * The key is `search.engine`, the Mac's. A key invented here would be a setting the other
     * platform never sees change — which looks exactly like a setting that does not work.
     */
    @Test
    fun theSearchEngineRoundTripsThroughTheMacsKey() {
        open().use { database ->
            val settings = SettingsStore(database)
            assertEquals(SearchEngine.DUCK_DUCK_GO, settings.searchEngine)

            settings.searchEngine = SearchEngine.GOOGLE

            assertEquals("google", settings["search.engine"])
            assertEquals(SearchEngine.GOOGLE, settings.searchEngine)
        }
    }

    // MARK: -

    private fun AppDatabase.hasTable(name: String): Boolean =
        prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name = ?") {
            it.bindText(1, name)
            it.step()
            it.getLong(0) > 0
        }

    private fun AppDatabase.columns(table: String): List<String> {
        val names = mutableListOf<String>()
        prepare("SELECT name FROM pragma_table_info(?)") {
            it.bindText(1, table)
            while (it.step()) names.add(it.getText(0))
        }
        return names
    }
}
