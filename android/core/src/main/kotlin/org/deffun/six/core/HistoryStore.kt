package org.deffun.six.core

import java.time.Instant
import java.util.UUID

/** One visit. History is per profile, like everything else the profile isolates. */
data class Visit(
    val id: UUID,
    val profileId: UUID,
    val url: String,
    val title: String = "",
    val visitedAt: Instant,
)

/**
 * Browsing history for every profile, in the `visits` table — the same rows the Mac reads.
 *
 * The behaviour is the Mac's `HistoryStore`, not a reimplementation of "write a row per page":
 * revisiting the page you are already on updates the last visit rather than stacking another, and a
 * title arriving after the navigation commits updates the newest visit of that address. Two front
 * ends that disagree about this produce a history that looks corrupted from whichever one you are
 * reading it in.
 */
class HistoryStore(private val database: AppDatabase) {

    /**
     * A committed navigation. Reloading or re-visiting the page you're already on doesn't stack up.
     *
     * @return the visit that was written or refreshed, or null when the address is not recordable.
     */
    fun record(url: String, title: String, profileId: UUID, now: Instant = Instant.now()): Visit? {
        if (!isRecordable(url)) return null

        return database.transaction {
            val last = latestVisit(profileId)
            if (last != null && last.url == url) {
                val merged = last.copy(
                    visitedAt = now,
                    // An empty title does not erase one that arrived earlier.
                    title = if (title.isEmpty()) last.title else title,
                )
                update(merged)
                merged
            } else {
                val visit = Visit(UUID.randomUUID(), profileId, url, title, now)
                insert(visit)
                visit
            }
        }
    }

    /** Titles usually arrive after the navigation commits; update the latest visit of that page. */
    fun updateTitle(title: String, url: String, profileId: UUID) {
        if (title.isEmpty()) return
        database.transaction {
            val latest = latestVisit(profileId, url) ?: return@transaction
            update(latest.copy(title = title))
        }
    }

    /** Every visit of the profile, newest first. */
    fun entries(profileId: UUID, limit: Int = Int.MAX_VALUE): List<Visit> {
        val visits = mutableListOf<Visit>()
        database.prepare(
            """
            SELECT "id", "profileID", "url", "title", "visitedAt" FROM "visits"
            WHERE "profileID" = ? ORDER BY "visitedAt" DESC LIMIT ?
            """.trimIndent(),
        ) { statement ->
            statement.bindText(1, profileId.toSqlText())
            statement.bindLong(2, limit.toLong())
            while (statement.step()) visits.add(statement.readVisit())
        }
        return visits
    }

    fun remove(id: UUID) {
        database.prepare("""DELETE FROM "visits" WHERE "id" = ?""") {
            it.bindText(1, id.toSqlText())
            it.step()
        }
    }

    fun clear(profileId: UUID) {
        database.prepare("""DELETE FROM "visits" WHERE "profileID" = ?""") {
            it.bindText(1, profileId.toSqlText())
            it.step()
        }
    }

    // MARK: -

    private fun latestVisit(profileId: UUID, url: String? = null): Visit? {
        val sql = buildString {
            append("""SELECT "id", "profileID", "url", "title", "visitedAt" FROM "visits" WHERE "profileID" = ?""")
            if (url != null) append(""" AND "url" = ?""")
            append(""" ORDER BY "visitedAt" DESC LIMIT 1""")
        }
        return database.prepare(sql) { statement ->
            statement.bindText(1, profileId.toSqlText())
            if (url != null) statement.bindText(2, url)
            if (statement.step()) statement.readVisit() else null
        }
    }

    private fun insert(visit: Visit) {
        database.prepare(
            """INSERT INTO "visits" ("id", "profileID", "url", "title", "visitedAt") VALUES (?, ?, ?, ?, ?)""",
        ) { statement ->
            statement.bindText(1, visit.id.toSqlText())
            statement.bindText(2, visit.profileId.toSqlText())
            statement.bindText(3, visit.url)
            statement.bindText(4, visit.title)
            statement.bindText(5, GrdbDate.format(visit.visitedAt))
            statement.step()
        }
    }

    private fun update(visit: Visit) {
        database.prepare(
            """UPDATE "visits" SET "title" = ?, "visitedAt" = ? WHERE "id" = ?""",
        ) { statement ->
            statement.bindText(1, visit.title)
            statement.bindText(2, GrdbDate.format(visit.visitedAt))
            statement.bindText(3, visit.id.toSqlText())
            statement.step()
        }
    }

    private fun androidx.sqlite.SQLiteStatement.readVisit() = Visit(
        id = uuidFromSqlText(getText(0)),
        profileId = uuidFromSqlText(getText(1)),
        url = getText(2),
        title = getText(3),
        visitedAt = GrdbDate.parse(getText(4)),
    )

    companion object {
        /** The Mac's rule, and the reason `six://start` and `about:blank` never reach the table. */
        fun isRecordable(url: String): Boolean {
            val scheme = url.substringBefore(':', missingDelimiterValue = "").lowercase()
            return scheme == "http" || scheme == "https" || scheme == "file"
        }
    }
}
