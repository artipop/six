package org.deffun.six.core

import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * A saved page. The row is the record; the readable copy is a Markdown file in the profile's
 * `Bookmarks` folder, and the searchable form is `bookmark_chunks`.
 *
 * Every column the Mac's table has, including the four this platform does not fill in yet —
 * `indexedAt`, `embeddingModel`, `indexError` and the refresh triple. They are read and written back
 * unchanged rather than dropped: a bookmark saved on the Mac, opened here and edited would otherwise
 * come back having forgotten that it was ever indexed.
 */
data class Bookmark(
    val id: UUID,
    val profileId: UUID,
    val url: String,
    val title: String = "",
    /** The page's own description, or the first paragraph. */
    val excerpt: String = "",
    val siteName: String = "",
    val imageUrl: String? = null,
    /** Name of the Markdown file inside the profile's bookmarks folder. */
    val fileName: String = "",
    /** BCP-47 tag as the page declared it, e.g. `ru`, `en`. */
    val language: String = "",
    /** Length of the readable text — a hint of how much was saved. */
    val characterCount: Int = 0,
    val createdAt: Instant,
    /** When the chunks were embedded. Always null here: this platform does not embed yet. */
    val indexedAt: Instant? = null,
    val embeddingModel: String = "",
    val indexError: String? = null,
    val refreshedAt: Instant? = null,
    /** SHA-256 of the readable text, so a refresh that finds the same page changes nothing. */
    val contentHash: String = "",
    val refreshError: String? = null,
) {
    val lastReadAt: Instant get() = refreshedAt ?: createdAt

    val displayTitle: String get() = title.ifEmpty { url }

    val displayDetail: String
        get() = siteName.ifEmpty { runCatching { java.net.URI(url).host }.getOrNull() ?: url }
}

/**
 * One passage of a bookmark's text, in reading order. Chunk 0 is the title and excerpt, so a search
 * for what a page is about finds it even when the body is long.
 */
data class BookmarkChunk(
    val id: UUID,
    val bookmarkId: UUID,
    val ord: Int,
    val text: String,
)

/** Which bookmarks a search sees: the current profile's, or everyone's. */
enum class BookmarkScope(val id: String) {
    PROFILE("profile"),
    ALL("all"),
    ;

    companion object {
        fun from(id: String?): BookmarkScope = entries.firstOrNull { it.id == id } ?: PROFILE
    }
}

/** A search result: the bookmark, how well it matched, and the passage that matched. */
data class BookmarkHit(
    val bookmark: Bookmark,
    /** 0…1, higher is better. Text matches are fixed, as on the Mac. */
    val score: Double,
    val snippet: String,
)

/**
 * How a saved page becomes a file, a name and a set of passages.
 *
 * All of it is the Mac's arithmetic, because all of it ends up in files and rows that both read.
 *
 * ## One divergence, bounded and named
 *
 * The lengths below are counted in UTF-16 units here and in grapheme clusters on the Mac. For text
 * without astral characters or combining marks the two agree exactly; for text with them a chunk
 * boundary can land a character or two apart. That costs nothing while this platform does not embed
 * — the passages are still the same passages — and it becomes a real question the day it does, since
 * two devices chunking differently produce two different vectors for the same page.
 */
object BookmarkText {

    /** Passages are cut around this many characters; a paragraph longer than [MAX_CHUNK] is split. */
    const val CHUNK_TARGET = 900
    const val MAX_CHUNK = 1400
    const val MAX_CHUNKS = 120

    /** Title and excerpt first, then the text in paragraph-sized passages. */
    fun chunks(title: String, excerpt: String, text: String): List<String> {
        val result = mutableListOf<String>()
        val head = listOf(title, excerpt).filter { it.isNotEmpty() }.joinToString("\n")
        if (head.isNotEmpty()) result.add(head)

        var current = StringBuilder()
        fun flush() {
            val trimmed = current.toString().trim()
            if (trimmed.isNotEmpty()) result.add(trimmed)
            current = StringBuilder()
        }

        for (raw in text.split("\n\n")) {
            val paragraph = raw.trim()
            if (paragraph.isEmpty()) continue
            if (current.length + paragraph.length > CHUNK_TARGET && current.isNotEmpty()) flush()
            if (paragraph.length > MAX_CHUNK) {
                flush()
                result.addAll(split(paragraph, MAX_CHUNK))
            } else {
                if (current.isNotEmpty()) current.append("\n\n")
                current.append(paragraph)
            }
            if (result.size >= MAX_CHUNKS) break
        }
        flush()
        return result.take(MAX_CHUNKS)
    }

    /** Cuts at sentence ends where it can, hard where it must. */
    private fun split(text: String, limit: Int): List<String> {
        val pieces = mutableListOf<String>()
        var rest = text
        while (rest.length > limit) {
            val window = rest.substring(0, limit)
            val lastStop = window.indexOfLast { it in ".!?\n" }
            val cut = if (lastStop >= 0) lastStop + 1 else window.length
            val piece = rest.substring(0, cut).trim()
            if (piece.isNotEmpty()) pieces.add(piece)
            rest = rest.substring(cut)
        }
        val tail = rest.trim()
        if (tail.isNotEmpty()) pieces.add(tail)
        return pieces
    }

    /**
     * `<title slug>-<first 8 of the id>.md`, ASCII-folded so it is the same on any file system.
     *
     * Folded rather than transliterated: a Cyrillic title keeps its letters, which is what the Mac
     * does too — the folding is about accents and case, not alphabet.
     */
    fun fileName(title: String, id: UUID): String {
        val slug = buildString {
            for (character in title.lowercase()) {
                if (character.isLetterOrDigit()) append(character)
                else if (!endsWith("-")) append('-')
            }
        }.trim('-').let { if (it.length > 60) it.take(60).trim('-') else it }

        val short = id.toString().take(8).lowercase()
        return (if (slug.isEmpty()) short else "$slug-$short") + ".md"
    }

    fun hash(text: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray())
            .joinToString("") { "%02x".format(it) }

    /**
     * Markdown with YAML front matter — readable in any editor, and enough to rebuild the row.
     *
     * The front matter is what a person opening the folder sees first, so its order is the Mac's and
     * not alphabetical.
     */
    fun document(
        bookmark: Bookmark,
        byline: String,
        profileName: String,
        markdown: String,
    ): String {
        fun quoted(value: String) =
            "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

        val lines = mutableListOf(
            "---",
            "title: ${quoted(bookmark.title)}",
            "url: ${bookmark.url}",
            "site: ${quoted(bookmark.siteName)}",
        )
        if (byline.isNotEmpty()) lines.add("author: ${quoted(byline)}")
        bookmark.imageUrl?.let { lines.add("image: $it") }
        if (bookmark.language.isNotEmpty()) lines.add("language: ${bookmark.language}")
        lines.add("profile: ${quoted(profileName)}")
        lines.add("saved: ${ISO_8601.format(bookmark.createdAt)}")
        lines.add("id: ${bookmark.id.toString().uppercase()}")
        lines.add("---")
        lines.add("")
        if (bookmark.title.isNotEmpty() && !markdown.startsWith("# ")) {
            lines.add("# ${bookmark.title}")
            lines.add("")
        }
        lines.add(markdown)
        lines.add("")
        return lines.joinToString("\n")
    }

    /** `ISO8601DateFormatter()`'s default: seconds, `Z`, no fraction. */
    private val ISO_8601: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
            .withZone(java.time.ZoneOffset.UTC)
}
