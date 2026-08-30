package org.deffun.six.core

import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * Bookmarks: the row, the readable Markdown file, and the passages.
 *
 * What is *not* here is the index. The Mac embeds each passage and searches by meaning; this
 * platform does not embed yet ([docs/android.md] puts that in phase two), so [search] is the text
 * half alone — which the Mac's own comment already calls "the fallback when there is no model".
 *
 * The passages are still written. They are plain text, they are what an index is built *from*, and
 * writing them now means the day there is an embedder it can run over what is already saved rather
 * than fetching every page again.
 *
 * The four index columns are read and written back untouched rather than dropped, for the same
 * reason the snapshot carries branches it does not model: a bookmark saved on the Mac and edited
 * here must not come back having forgotten that it was ever indexed.
 */
class BookmarkStore(
    private val database: AppDatabase,
    /** `.../Profiles/<name>/Bookmarks`, the folder the Mac writes the same files into. */
    private val bookmarksFolder: (profileId: UUID) -> File?,
) {

    /**
     * Writes the file, the row and the passages for a page just read.
     *
     * Saving a page that is already bookmarked keeps its id, its file name and its `createdAt`, and
     * stamps `refreshedAt` — the same row re-read rather than a second bookmark for one address.
     */
    fun save(
        page: ReadablePage,
        url: String,
        fallbackTitle: String,
        profileId: UUID,
        profileName: String,
        now: Instant = Instant.now(),
    ): Bookmark {
        val existing = bookmark(url, profileId)
        val id = existing?.id ?: UUID.randomUUID()
        val title = page.title.ifEmpty { fallbackTitle }
        val fileName = existing?.fileName?.ifEmpty { null } ?: BookmarkText.fileName(title, id)

        val bookmark = Bookmark(
            id = id,
            profileId = profileId,
            url = url,
            title = title,
            excerpt = page.excerpt,
            siteName = page.siteName,
            imageUrl = page.imageUrl,
            fileName = fileName,
            language = page.language,
            characterCount = page.text.length,
            createdAt = existing?.createdAt ?: now,
            // Untouched from whatever wrote them, which on this platform is only ever the Mac.
            indexedAt = existing?.indexedAt,
            embeddingModel = existing?.embeddingModel.orEmpty(),
            indexError = existing?.indexError,
            refreshedAt = if (existing != null) now else null,
            contentHash = BookmarkText.hash(page.text),
            refreshError = null,
        )

        database.transaction {
            upsert(bookmark)
            replaceChunks(bookmark, BookmarkText.chunks(title, page.excerpt, page.text))
        }

        // The file after the row: a row with no file reads as a bookmark whose copy is missing,
        // which is recoverable, and a file with no row is litter nothing will ever clean up.
        writeDocument(bookmark, page, profileName)
        return bookmark
    }

    fun remove(id: UUID) {
        val bookmark = bookmark(id) ?: return
        database.transaction {
            execute("""DELETE FROM "bookmark_chunks" WHERE "bookmarkID" = ?""", id.toSqlText())
            execute("""DELETE FROM "bookmarks" WHERE "id" = ?""", id.toSqlText())
        }
        runCatching { fileOf(bookmark)?.delete() }
    }

    // MARK: Reading

    fun bookmark(id: UUID): Bookmark? =
        query("""$COLUMNS FROM "bookmarks" WHERE "id" = ? LIMIT 1""", id.toSqlText()).firstOrNull()

    fun bookmark(url: String, profileId: UUID): Bookmark? =
        query(
            """$COLUMNS FROM "bookmarks" WHERE "profileID" = ? AND "url" = ? LIMIT 1""",
            profileId.toSqlText(),
            url,
        ).firstOrNull()

    /** Newest first, the way the panel shows them. */
    fun entries(profileId: UUID, scope: BookmarkScope = BookmarkScope.PROFILE): List<Bookmark> =
        if (scope == BookmarkScope.ALL) {
            query("""$COLUMNS FROM "bookmarks" ORDER BY "createdAt" DESC""")
        } else {
            query(
                """$COLUMNS FROM "bookmarks" WHERE "profileID" = ? ORDER BY "createdAt" DESC""",
                profileId.toSqlText(),
            )
        }

    fun chunks(bookmarkId: UUID): List<BookmarkChunk> {
        val chunks = mutableListOf<BookmarkChunk>()
        database.connection.prepare(
            """SELECT "id", "bookmarkID", "ord", "text" FROM "bookmark_chunks" WHERE "bookmarkID" = ? ORDER BY "ord"""",
        ).use { statement ->
            statement.bindText(1, bookmarkId.toSqlText())
            while (statement.step()) {
                chunks.add(
                    BookmarkChunk(
                        id = uuidFromSqlText(statement.getText(0)),
                        bookmarkId = uuidFromSqlText(statement.getText(1)),
                        ord = statement.getLong(2).toInt(),
                        text = statement.getText(3),
                    ),
                )
            }
        }
        return chunks
    }

    /** The Markdown file, front matter included. */
    fun content(bookmark: Bookmark): String? =
        fileOf(bookmark)?.takeIf { it.isFile }?.readText()

    fun fileOf(bookmark: Bookmark): File? {
        if (bookmark.fileName.isEmpty()) return null
        return bookmarksFolder(bookmark.profileId)?.let { File(it, bookmark.fileName) }
    }

    /**
     * Text search, which is all there is without an embedder.
     *
     * Every word of three letters or more has to be there — a stray "в" or "in" must not count as a
     * match — and the passages are searched as well as the row, so a page found by something it said
     * rather than by its title comes back with the sentence that matched.
     */
    fun search(
        query: String,
        profileId: UUID,
        scope: BookmarkScope = BookmarkScope.PROFILE,
        limit: Int = 20,
    ): List<BookmarkHit> {
        val trimmed = query.trim()
        val candidates = entries(profileId, scope)
        if (trimmed.isEmpty()) {
            return candidates.take(limit).map { BookmarkHit(it, 0.0, it.excerpt) }
        }

        val terms = trimmed.split(Regex("\\s+")).map { it.lowercase() }.filter { it.length >= 3 }
        if (terms.isEmpty()) {
            return candidates.take(limit).map { BookmarkHit(it, 0.0, it.excerpt) }
        }

        val hits = mutableListOf<BookmarkHit>()
        for (bookmark in candidates) {
            val haystack = listOf(bookmark.title, bookmark.url, bookmark.excerpt, bookmark.siteName)
                .joinToString(" ")
                .lowercase()
            if (terms.all { haystack.contains(it) }) {
                hits.add(BookmarkHit(bookmark, TEXT_SCORE, bookmark.excerpt))
                continue
            }
            val passage = chunks(bookmark.id).firstOrNull { chunk ->
                val text = chunk.text.lowercase()
                terms.all { text.contains(it) }
            }
            if (passage != null) hits.add(BookmarkHit(bookmark, PASSAGE_SCORE, snippet(passage.text, terms)))
            if (hits.size >= limit) break
        }
        return hits
    }

    // MARK: -

    private fun snippet(text: String, terms: List<String>): String {
        val at = text.lowercase().indexOf(terms.first()).coerceAtLeast(0)
        val start = (at - 80).coerceAtLeast(0)
        val end = (start + 240).coerceAtMost(text.length)
        return buildString {
            if (start > 0) append("…")
            append(text.substring(start, end).trim())
            if (end < text.length) append("…")
        }
    }

    private fun writeDocument(bookmark: Bookmark, page: ReadablePage, profileName: String) {
        val file = fileOf(bookmark) ?: return
        runCatching {
            file.parentFile?.mkdirs()
            file.writeText(BookmarkText.document(bookmark, page.byline, profileName, page.markdown))
        }
    }

    private fun upsert(bookmark: Bookmark) {
        // An explicit upsert: `ON CONFLICT REPLACE` on this schema binds to NOT NULL, not to the
        // primary key, so a plain insert on an existing id raises rather than replacing.
        database.connection.prepare(
            """
            INSERT INTO "bookmarks" (
              "id", "profileID", "url", "title", "excerpt", "siteName", "imageURL", "fileName",
              "language", "characterCount", "createdAt", "indexedAt", "embeddingModel", "indexError",
              "refreshedAt", "contentHash", "refreshError"
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT("id") DO UPDATE SET
              "url" = excluded."url", "title" = excluded."title", "excerpt" = excluded."excerpt",
              "siteName" = excluded."siteName", "imageURL" = excluded."imageURL",
              "fileName" = excluded."fileName", "language" = excluded."language",
              "characterCount" = excluded."characterCount", "indexedAt" = excluded."indexedAt",
              "embeddingModel" = excluded."embeddingModel", "indexError" = excluded."indexError",
              "refreshedAt" = excluded."refreshedAt", "contentHash" = excluded."contentHash",
              "refreshError" = excluded."refreshError"
            """.trimIndent(),
        ).use { statement ->
            statement.bindText(1, bookmark.id.toSqlText())
            statement.bindText(2, bookmark.profileId.toSqlText())
            statement.bindText(3, bookmark.url)
            statement.bindText(4, bookmark.title)
            statement.bindText(5, bookmark.excerpt)
            statement.bindText(6, bookmark.siteName)
            bookmark.imageUrl?.let { statement.bindText(7, it) } ?: statement.bindNull(7)
            statement.bindText(8, bookmark.fileName)
            statement.bindText(9, bookmark.language)
            statement.bindLong(10, bookmark.characterCount.toLong())
            statement.bindText(11, GrdbDate.format(bookmark.createdAt))
            bookmark.indexedAt?.let { statement.bindText(12, GrdbDate.format(it)) } ?: statement.bindNull(12)
            statement.bindText(13, bookmark.embeddingModel)
            bookmark.indexError?.let { statement.bindText(14, it) } ?: statement.bindNull(14)
            bookmark.refreshedAt?.let { statement.bindText(15, GrdbDate.format(it)) } ?: statement.bindNull(15)
            statement.bindText(16, bookmark.contentHash)
            bookmark.refreshError?.let { statement.bindText(17, it) } ?: statement.bindNull(17)
            statement.step()
        }
    }

    /** Replaced whole: a page re-read has different passages, and half of each would be worse. */
    private fun replaceChunks(bookmark: Bookmark, texts: List<String>) {
        execute("""DELETE FROM "bookmark_chunks" WHERE "bookmarkID" = ?""", bookmark.id.toSqlText())
        database.connection.prepare(
            """INSERT INTO "bookmark_chunks" ("id", "bookmarkID", "ord", "text") VALUES (?, ?, ?, ?)""",
        ).use { statement ->
            texts.forEachIndexed { ord, text ->
                statement.reset()
                statement.bindText(1, UUID.randomUUID().toSqlText())
                statement.bindText(2, bookmark.id.toSqlText())
                statement.bindLong(3, ord.toLong())
                statement.bindText(4, text)
                statement.step()
            }
        }
    }

    private fun execute(sql: String, vararg arguments: String) {
        database.connection.prepare(sql).use { statement ->
            arguments.forEachIndexed { index, value -> statement.bindText(index + 1, value) }
            statement.step()
        }
    }

    private fun query(sql: String, vararg arguments: String): List<Bookmark> {
        val bookmarks = mutableListOf<Bookmark>()
        database.connection.prepare(sql).use { statement ->
            arguments.forEachIndexed { index, value -> statement.bindText(index + 1, value) }
            while (statement.step()) bookmarks.add(statement.readBookmark())
        }
        return bookmarks
    }

    private fun androidx.sqlite.SQLiteStatement.readBookmark() = Bookmark(
        id = uuidFromSqlText(getText(0)),
        profileId = uuidFromSqlText(getText(1)),
        url = getText(2),
        title = getText(3),
        excerpt = getText(4),
        siteName = getText(5),
        imageUrl = if (isNull(6)) null else getText(6),
        fileName = getText(7),
        language = getText(8),
        characterCount = getLong(9).toInt(),
        createdAt = GrdbDate.parse(getText(10)),
        indexedAt = if (isNull(11)) null else GrdbDate.parse(getText(11)),
        embeddingModel = getText(12),
        indexError = if (isNull(13)) null else getText(13),
        refreshedAt = if (isNull(14)) null else GrdbDate.parse(getText(14)),
        contentHash = getText(15),
        refreshError = if (isNull(16)) null else getText(16),
    )

    private companion object {
        /** Column order is the read order; the two are written once and must not drift apart. */
        const val COLUMNS = """
            SELECT "id", "profileID", "url", "title", "excerpt", "siteName", "imageURL", "fileName",
                   "language", "characterCount", "createdAt", "indexedAt", "embeddingModel",
                   "indexError", "refreshedAt", "contentHash", "refreshError"
        """

        /** The Mac's fixed scores for a text match, so the two rank the same way. */
        const val TEXT_SCORE = 0.5
        const val PASSAGE_SCORE = 0.4
    }
}
