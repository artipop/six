package org.deffun.six.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * One connection, several callers.
 *
 * This is the shape every other test here avoided by accident: they open a database, use it from the
 * thread they are on, and close it. The app does not — a page committing a visit, the snapshot being
 * written and a bookmark being saved are three coroutines on the IO dispatcher, and they arrive at
 * once. Two transactions interleaving on one connection is not a lost write but a crash: `cannot
 * start a transaction within a transaction`.
 *
 * GRDB gives the Mac that guarantee by owning a writer queue. It had to be given here too, and it
 * was found by launching the app rather than by any of the 137 tests that came before this one.
 */
class ConcurrentWriteTest {

    private val directory: File = Files.createTempDirectory("six-concurrent").toFile()
    private val database = AppDatabase.open(File(directory, AppDatabase.FILE_NAME))

    @AfterTest
    fun cleanUp() {
        database.close()
        directory.deleteRecursively()
    }

    @Test
    fun manyWritersOnOneConnectionDoNotCollide() {
        val history = HistoryStore(database)
        val settings = SettingsStore(database)
        val bookmarks = BookmarkStore(database) { File(directory, "Bookmarks") }
        val profile = UUID.randomUUID()

        val workers = 8
        val rounds = 25
        val pool = Executors.newFixedThreadPool(workers)
        val start = CountDownLatch(1)
        val failures = java.util.Collections.synchronizedList(mutableListOf<Throwable>())

        repeat(workers) { worker ->
            pool.execute {
                start.await()
                runCatching {
                    repeat(rounds) { round ->
                        // A transaction, from `record`.
                        history.record("https://example.org/$worker/$round", "page", profile)
                        // A single statement, from the settings table.
                        settings["worker.$worker"] = "$round"
                        // And a transaction that writes two tables, from a bookmark.
                        bookmarks.save(
                            ReadablePage(title = "t$worker", excerpt = "e", text = "body $round"),
                            "https://example.org/saved/$worker/$round",
                            "fallback",
                            profile,
                            "Personal",
                        )
                    }
                }.onFailure { failures.add(it) }
            }
        }

        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(60, TimeUnit.SECONDS), "the writers did not finish")

        assertEquals(
            emptyList(),
            failures.map { "${it::class.simpleName}: ${it.message}" },
            "concurrent writes collided",
        )

        // And everything actually landed.
        assertEquals(workers * rounds, history.entries(profile).size)
        assertEquals(workers * rounds, bookmarks.entries(profile).size)
        assertEquals(workers, settings.all().size)
    }

    /** A transaction holds the connection: nothing else may begin one while it runs. */
    @Test
    fun aTransactionIsNotInterruptedByAnotherThread() {
        val inside = CountDownLatch(1)
        val other = CountDownLatch(1)
        val settings = SettingsStore(database)
        var failure: Throwable? = null

        val thread = Thread {
            inside.await()
            runCatching { database.transaction { settings["from.other"] = "yes" } }
                .onFailure { failure = it }
            other.countDown()
        }
        thread.start()

        database.transaction {
            settings["from.this"] = "yes"
            inside.countDown()
            // The other thread is now trying to begin a transaction; it has to wait for this one.
            assertTrue(!other.await(300, TimeUnit.MILLISECONDS), "another transaction began inside this one")
        }

        assertTrue(other.await(10, TimeUnit.SECONDS), "the waiting transaction never ran")
        thread.join()

        assertEquals(null, failure?.message)
        assertEquals("yes", settings["from.this"])
        assertEquals("yes", settings["from.other"])
    }
}
