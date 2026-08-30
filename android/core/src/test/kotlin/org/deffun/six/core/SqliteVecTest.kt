package org.deffun.six.core

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue

/**
 * Whether this platform can carry the Mac's vector index.
 *
 * `bookmark_vec_384` is a `vec0` virtual table, and after migration v4 the Mac's vectors live only
 * there — so reading them at all needs the sqlite-vec module, and building an index of our own needs
 * it too unless we settle for a brute-force scan.
 *
 * ## What this establishes, and what it does not
 *
 * It runs on the JVM, against `androidx.sqlite`'s **bundled** SQLite — the same library, the same
 * version and the same compile options that ship inside the app. So what passes here answers the
 * question that was actually open: whether that SQLite has extension loading compiled in, and
 * whether `BundledSQLiteDriver.addExtension` really reaches it.
 *
 * It does not answer the Android half, which is packaging rather than SQLite — see docs/android.md.
 *
 * ## The blob, not the JSON
 *
 * Vectors go in as a little-endian float32 blob, which is what the Mac's `BookmarkStore.blob` writes
 * and what any shared index would hold. That is not a preference here: with this pairing — the
 * bundled SQLite 3.50.1 against a sqlite-vec built later — every JSON text form is rejected with a
 * parsing error, including one produced by SQLite's own `json_array()`. The blob path works
 * perfectly. Worth knowing before someone reaches for the documented `'[0.1,0.2]'` syntax and
 * concludes the extension is broken.
 *
 * Skipped until `android/tools/sqlite-vec/fetch.sh` has been run: a test that downloads its own
 * subject fails for reasons that have nothing to do with the code.
 */
class SqliteVecTest {

    private val extension = File("build/sqlite-vec").listFiles()
        ?.firstOrNull { it.name.startsWith("vec0.") }

    private val directory: File = Files.createTempDirectory("six-vec").toFile()

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
    }

    private fun blob(vector: FloatArray): ByteArray {
        val buffer = ByteBuffer.allocate(vector.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (value in vector) buffer.putFloat(value)
        return buffer.array()
    }

    @Test
    fun theBundledSqliteLoadsSqliteVecAndAnswersANearestNeighbourQuery() {
        assumeTrue(
            extension != null,
            "run android/tools/sqlite-vec/fetch.sh first",
        )

        val driver = BundledSQLiteDriver()
        // The entry point has to be named. SQLite derives one from the file name otherwise, and the
        // file is `vec0.so`, which would send it looking for `sqlite3_vec0_init`.
        driver.addExtension(extension!!.path, "sqlite3_vec_init")

        val connection = driver.open(File(directory, "vectors.db").path)
        try {
            connection.prepare("SELECT vec_version()").use {
                assertTrue(it.step(), "vec_version() returned nothing")
                assertTrue(it.getText(0).startsWith("v0."), "unexpected version: ${it.getText(0)}")
            }

            // 384 dimensions, because that is what multilingual-e5-small produces and what the Mac's
            // `bookmark_vec_384` holds.
            connection.execSQL("CREATE VIRTUAL TABLE vectors USING vec0(embedding float[384])")

            val near = FloatArray(384) { 0.1f }
            val far = FloatArray(384) { it -> if (it % 2 == 0) 0.9f else -0.9f }
            for ((id, vector) in listOf(1L to near, 2L to far)) {
                connection.prepare("INSERT INTO vectors(rowid, embedding) VALUES (?, ?)").use {
                    it.bindLong(1, id)
                    it.bindBlob(2, blob(vector))
                    it.step()
                }
            }

            val hits = mutableListOf<Pair<Long, Double>>()
            connection.prepare(
                "SELECT rowid, distance FROM vectors WHERE embedding MATCH ? AND k = 2",
            ).use {
                it.bindBlob(1, blob(near))
                while (it.step()) hits.add(it.getLong(0) to it.getDouble(1))
            }

            assertEquals(2, hits.size, "the index returned the wrong number of neighbours")
            assertEquals(1L, hits.first().first, "the exact match was not nearest")
            assertEquals(0.0, hits.first().second, "an exact match should be at distance zero")
            assertTrue(hits[1].second > hits[0].second, "the neighbours came back out of order")
        } finally {
            connection.close()
        }
    }
}
