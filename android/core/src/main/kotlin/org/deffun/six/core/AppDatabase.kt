package org.deffun.six.core

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The one SQLite file, opened here the way the Mac opens it.
 *
 * ## Who owns the schema
 *
 * GRDB does, on the Mac. Android is a second writer of a file someone else defines, and the whole
 * design of this class follows from that:
 *
 * - **Migrations are identified by name, in `grdb_migrations`** — not by `PRAGMA user_version`,
 *   which is 0 in a real six database and always will be. The four identifiers below are GRDB's own
 *   strings, character for character. Get one wrong and both sides run their own copy of the same
 *   migration: the Mac's `CREATE TABLE` then fails against a table Android already made, and the
 *   app does not start.
 * - **Only missing migrations run, in order**, which is what GRDB does. A database carrying
 *   identifiers this build has never heard of was written by a newer Mac; that is not an error and
 *   not something to repair — the tables Android reads are still there, and anything else is the
 *   Mac's business.
 * - **Nothing is ever dropped or altered outside a migration.**
 *
 * ## The table Android cannot open
 *
 * `bookmark_vec_384` is a `vec0` virtual table, created by sqlite-vec, which is not loaded here
 * ([docs/android.md](../../../../../../docs/android.md) puts vectors in phase two). A connection
 * without the module opens the database, reads `visits`, `settings`, `bookmarks` and
 * `bookmark_chunks` perfectly well, and fails only on a statement that names the virtual table
 * itself — verified against the real file rather than assumed. So the rule is simply never to name
 * it: no `SELECT *` across the schema, no schema-wide maintenance, no `VACUUM`.
 */
class AppDatabase private constructor(
    private val handle: SQLiteConnection,
) : AutoCloseable {

    /**
     * One connection, one thread at a time.
     *
     * A SQLite connection is not a thing several callers may use at once, and this one has several:
     * a page committing a visit, the snapshot being written, a bookmark being saved — all on the IO
     * dispatcher, all at once. Without this, two of them interleave and the second gets `cannot
     * start a transaction within a transaction`, which is a crash rather than a lost write.
     *
     * GRDB gives the Mac the same guarantee by owning a writer queue; here it is a reentrant lock,
     * reentrant so that a store may take it around a group of statements that are themselves already
     * inside a transaction.
     *
     * Found by running the app, not by a test: every test until now used one database from one
     * thread, which is the one shape this problem cannot happen in.
     */
    private val lock = ReentrantLock()

    /**
     * The connection, for the length of one piece of work.
     *
     * Everything that touches SQLite goes through here. Handing the connection out as a property was
     * what made it possible to use it from two threads without noticing.
     */
    fun <T> withConnection(body: (SQLiteConnection) -> T): T = lock.withLock { body(handle) }

    /** One prepared statement, used and closed, with the connection held for exactly that long. */
    fun <T> prepare(sql: String, body: (SQLiteStatement) -> T): T =
        withConnection { connection -> connection.prepare(sql).use(body) }

    fun execute(sql: String) = withConnection { it.execSQL(sql) }

    data class Migration(val identifier: String, val statements: List<String>)

    companion object {
        /** The file's name inside six's application-support directory, on every platform. */
        const val FILE_NAME = "six.sqlite"

        /**
         * GRDB's identifiers, verbatim. The commas and the spacing are part of the string and part
         * of the contract; they are not descriptions.
         */
        val MIGRATIONS: List<Migration> = listOf(
            Migration(
                "v1 visits, settings",
                listOf(
                    """
                    CREATE TABLE "visits" (
                      "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                      "profileID" TEXT NOT NULL,
                      "url" TEXT NOT NULL,
                      "title" TEXT NOT NULL DEFAULT '',
                      "visitedAt" TEXT NOT NULL
                    ) STRICT
                    """,
                    """CREATE INDEX "visits_by_profile_time" ON "visits"("profileID", "visitedAt" DESC)""",
                    """
                    CREATE TABLE "settings" (
                      "key" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                      "value" TEXT NOT NULL
                    ) STRICT
                    """,
                ),
            ),
            Migration(
                "v2 bookmarks",
                listOf(
                    """
                    CREATE TABLE "bookmarks" (
                      "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                      "profileID" TEXT NOT NULL,
                      "url" TEXT NOT NULL,
                      "title" TEXT NOT NULL DEFAULT '',
                      "excerpt" TEXT NOT NULL DEFAULT '',
                      "siteName" TEXT NOT NULL DEFAULT '',
                      "imageURL" TEXT,
                      "fileName" TEXT NOT NULL DEFAULT '',
                      "language" TEXT NOT NULL DEFAULT '',
                      "characterCount" INTEGER NOT NULL DEFAULT 0,
                      "createdAt" TEXT NOT NULL,
                      "indexedAt" TEXT,
                      "embeddingModel" TEXT NOT NULL DEFAULT '',
                      "indexError" TEXT
                    ) STRICT
                    """,
                    """CREATE INDEX "bookmarks_by_profile_time" ON "bookmarks"("profileID", "createdAt" DESC)""",
                    """
                    CREATE TABLE "bookmark_chunks" (
                      "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                      "bookmarkID" TEXT NOT NULL,
                      "ord" INTEGER NOT NULL DEFAULT 0,
                      "text" TEXT NOT NULL
                    ) STRICT
                    """,
                    """CREATE INDEX "bookmark_chunks_by_bookmark" ON "bookmark_chunks"("bookmarkID", "ord")""",
                    // The float32-BLOB table the Mac scanned in Swift before sqlite-vec. It is
                    // created here and dropped again by v4, exactly as on the Mac: a migration list
                    // is a history, and replaying it differently is how two schemas diverge.
                    """
                    CREATE TABLE "bookmark_vectors" (
                      "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                      "chunkID" TEXT NOT NULL,
                      "bookmarkID" TEXT NOT NULL,
                      "profileID" TEXT NOT NULL,
                      "model" TEXT NOT NULL,
                      "embedding" BLOB NOT NULL
                    ) STRICT
                    """,
                    """CREATE INDEX "bookmark_vectors_by_model_profile" ON "bookmark_vectors"("model", "profileID")""",
                ),
            ),
            Migration(
                "v3 bookmark refresh",
                listOf(
                    """ALTER TABLE "bookmarks" ADD COLUMN "refreshedAt" TEXT""",
                    """ALTER TABLE "bookmarks" ADD COLUMN "contentHash" TEXT NOT NULL DEFAULT ''""",
                    """ALTER TABLE "bookmarks" ADD COLUMN "refreshError" TEXT""",
                ),
            ),
            Migration(
                "v4 vectors in vec0",
                // The vec0 tables themselves are not created by a migration on either platform —
                // `BookmarkStore` makes one per vector dimension, lazily. So Android can run this
                // one honestly: all it does is drop what v2 made.
                listOf("""DROP TABLE IF EXISTS "bookmark_vectors""""),
            ),
        )

        fun open(
            file: File,
            driver: SQLiteDriver = BundledSQLiteDriver(),
        ): AppDatabase {
            file.parentFile?.mkdirs()
            val connection = driver.open(file.path)
            // WAL is what the Mac's file is in, and a second process reading it wants the same.
            connection.execSQL("PRAGMA journal_mode = WAL")
            connection.execSQL("PRAGMA foreign_keys = ON")
            return AppDatabase(connection).also { it.migrate() }
        }
    }

    /** Identifiers already recorded in the file, whether or not this build knows them. */
    fun appliedMigrations(): Set<String> = withConnection { connection ->
        connection.execSQL("""CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)""")
        val applied = LinkedHashSet<String>()
        connection.prepare("SELECT identifier FROM grdb_migrations").use { statement ->
            while (statement.step()) applied.add(statement.getText(0))
        }
        applied
    }

    private fun migrate() {
        val applied = appliedMigrations()
        for (migration in MIGRATIONS) {
            if (migration.identifier in applied) continue
            transaction {
                withConnection { connection ->
                    for (sql in migration.statements) connection.execSQL(sql.trimIndent())
                    connection.prepare("INSERT INTO grdb_migrations (identifier) VALUES (?)").use {
                        it.bindText(1, migration.identifier)
                        it.step()
                    }
                }
            }
        }
    }

    /**
     * A transaction, held for as long as [body] runs — and holding the connection with it, so no
     * other caller can begin one inside it.
     */
    fun <T> transaction(body: () -> T): T = lock.withLock {
        handle.execSQL("BEGIN")
        try {
            val result = body()
            handle.execSQL("COMMIT")
            result
        } catch (error: Throwable) {
            runCatching { handle.execSQL("ROLLBACK") }
            throw error
        }
    }

    override fun close() = lock.withLock { handle.close() }
}
