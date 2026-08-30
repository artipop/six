package org.deffun.six.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The one table Android must never name.
 *
 * A real six database contains `bookmark_vec_384`, a `vec0` virtual table made by sqlite-vec. This
 * build does not load that extension, and a connection without it opens the file, reads `visits`,
 * `settings`, `bookmarks` and `bookmark_chunks` perfectly well, and fails with `no such module:
 * vec0` the moment a statement names the virtual table. Verified against the real file, not assumed.
 *
 * So the rule is not "handle the vector tables" but "never mention them", and it is the kind of rule
 * that is broken by a convenience: a `SELECT *` across the schema, a maintenance pass, a `VACUUM`.
 * None of those can be caught by opening a database in a test, because a test database has no vec0
 * table in it to trip over. A source check can.
 */
class VectorTableIsolationTest {

    // `bookmark_vectors` is not on this list: it is an ordinary table, created by v2 and dropped by
    // v4, and the migrations name it on purpose. What must never appear is a *virtual* one —
    // `bookmark_vec_384` and its siblings — or anything that walks the whole schema and finds them.
    private val forbidden = listOf("bookmark_vec_", "USING vec0", "VACUUM", "sqlite_master WHERE type='table'")

    @Test
    fun noStatementInTheStorageLayerNamesTheVectorTables() {
        val sources = File("src/main/kotlin")
        assertTrue(sources.isDirectory, "expected to run from the module directory, was ${File(".").absolutePath}")

        val offences = mutableListOf<String>()
        sources.walkTopDown().filter { it.extension == "kt" }.forEach { file ->
            file.readLines().forEachIndexed { index, line ->
                // Prose about the rule is the point of the rule; only code is checked.
                val code = line.substringBefore("//").trim()
                if (code.startsWith("*") || code.isEmpty()) return@forEachIndexed
                for (word in forbidden) {
                    if (code.contains(word)) offences.add("${file.name}:${index + 1}: $code")
                }
            }
        }

        if (offences.isNotEmpty()) {
            fail("the storage layer names a vec0 table or sweeps the schema:\n" + offences.joinToString("\n"))
        }
    }

    /** The migrations are the other place a vec table could be created or touched. */
    @Test
    fun noMigrationCreatesOrTouchesAVectorTable() {
        for (migration in AppDatabase.MIGRATIONS) {
            for (statement in migration.statements) {
                assertTrue(
                    !statement.contains("USING vec0") && !statement.contains("bookmark_vec_"),
                    "`${migration.identifier}` names a vec0 table: $statement",
                )
            }
        }
    }
}
