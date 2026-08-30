package org.deffun.six.core

import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Bookmarks: the row, the file and the passages — written into the same three places the Mac writes
 * them, so a folder opened on either device is one folder.
 */
class BookmarkStoreTest {

    private val directory: File = Files.createTempDirectory("six-bookmarks").toFile()
    private val database = AppDatabase.open(File(directory, AppDatabase.FILE_NAME))
    private val profile = UUID.randomUUID()
    private val store = BookmarkStore(database) { File(directory, "Profiles/Personal/Bookmarks") }

    @AfterTest
    fun cleanUp() {
        database.close()
        directory.deleteRecursively()
    }

    private fun page(
        title: String = "Pilaf",
        excerpt: String = "A rice dish.",
        text: String = "Pilaf is a rice dish.\n\nIt is cooked in stock.",
    ) = ReadablePage(
        title = title,
        byline = "A Cook",
        siteName = "en.wikipedia.org",
        excerpt = excerpt,
        image = "https://example.org/pilaf.jpg",
        language = "en",
        markdown = "# $title\n\n$text",
        text = text,
    )

    // MARK: Saving

    @Test
    fun savingWritesTheRowThePassagesAndTheFile() {
        val saved = store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")

        val row = assertNotNull(store.bookmark(saved.id))
        assertEquals("Pilaf", row.title)
        assertEquals("en.wikipedia.org", row.siteName)
        assertEquals("https://example.org/pilaf.jpg", row.imageUrl)
        assertEquals("en", row.language)
        assertEquals(BookmarkText.hash("Pilaf is a rice dish.\n\nIt is cooked in stock."), row.contentHash)

        val chunks = store.chunks(saved.id)
        assertTrue(chunks.isNotEmpty())
        assertEquals(0, chunks.first().ord, "the passages are not in reading order")
        assertContains(chunks.first().text, "Pilaf", message = "chunk 0 is not the title and excerpt")
        assertContains(chunks.first().text, "A rice dish.")

        val file = assertNotNull(store.fileOf(row))
        assertTrue(file.isFile, "the readable copy was not written")
        assertEquals("pilaf-${row.id.toString().take(8).lowercase()}.md", file.name)
    }

    /** The file is what a person opening the folder reads, so its front matter is the Mac's. */
    @Test
    fun theFileIsMarkdownWithTheMacsFrontMatter() {
        val saved = store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")
        val content = assertNotNull(store.content(saved))
        val lines = content.lines()

        assertEquals("---", lines[0])
        assertEquals("title: \"Pilaf\"", lines[1])
        assertEquals("url: https://example.org/pilaf", lines[2])
        assertEquals("site: \"en.wikipedia.org\"", lines[3])
        assertContains(content, "author: \"A Cook\"")
        assertContains(content, "image: https://example.org/pilaf.jpg")
        assertContains(content, "language: en")
        assertContains(content, "profile: \"Personal\"")
        assertContains(content, "id: ${saved.id.toString().uppercase()}")
        assertContains(content, "# Pilaf")
    }

    /** A title with quotes or backslashes must not break the document it is written into. */
    @Test
    fun theFrontMatterEscapesWhatWouldBreakIt() {
        val saved = store.save(
            page(title = "He said \"hello\" \\ goodbye"),
            "https://example.org/quotes",
            "fallback",
            profile,
            "Personal",
        )
        val content = assertNotNull(store.content(saved))
        assertContains(content, """title: "He said \"hello\" \\ goodbye"""")
    }

    /** Saving a page that is already bookmarked is the same row re-read, not a second bookmark. */
    @Test
    fun savingTheSamePageAgainKeepsTheRowAndStampsIt() {
        val first = store.save(
            page(),
            "https://example.org/pilaf",
            "fallback",
            profile,
            "Personal",
            now = Instant.parse("2026-08-01T10:00:00Z"),
        )
        val second = store.save(
            page(text = "Pilaf is a rice dish.\n\nIt is cooked in broth."),
            "https://example.org/pilaf",
            "fallback",
            profile,
            "Personal",
            now = Instant.parse("2026-08-30T10:00:00Z"),
        )

        assertEquals(first.id, second.id, "a second bookmark was made for one address")
        assertEquals(first.fileName, second.fileName, "the file moved out from under the folder")
        assertEquals(first.createdAt, second.createdAt, "the save date was overwritten")
        assertEquals(Instant.parse("2026-08-30T10:00:00Z"), second.refreshedAt)
        assertNull(first.refreshedAt, "a first save is not a refresh")
        assertEquals(1, store.entries(profile).size)

        // The passages are replaced whole: half of each would be worse than either.
        assertTrue(store.chunks(second.id).none { it.text.contains("stock") })
        assertTrue(store.chunks(second.id).any { it.text.contains("broth") })
    }

    /**
     * The index columns belong to a platform that is not this one. A bookmark saved on the Mac and
     * re-read here must not come back having forgotten that it was ever indexed.
     */
    @Test
    fun theIndexColumnsAreCarriedRatherThanCleared() {
        val saved = store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")

        // What the Mac would have written after embedding it.
        database.connection.prepare(
            """UPDATE "bookmarks" SET "indexedAt" = ?, "embeddingModel" = ?, "indexError" = ? WHERE "id" = ?""",
        ).use {
            it.bindText(1, GrdbDate.format(Instant.parse("2026-08-02T09:00:00Z")))
            it.bindText(2, "multilingual-e5-small")
            it.bindText(3, "a note from the Mac")
            it.bindText(4, saved.id.toSqlText())
            it.step()
        }

        val again = store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")

        assertEquals(Instant.parse("2026-08-02T09:00:00Z"), again.indexedAt)
        assertEquals("multilingual-e5-small", again.embeddingModel)
        assertEquals("a note from the Mac", again.indexError)
    }

    @Test
    fun bookmarksBelongToOneProfile() {
        val other = UUID.randomUUID()
        store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")
        store.save(page(title = "Plov"), "https://example.org/pilaf", "fallback", other, "Work")

        assertEquals(1, store.entries(profile).size)
        assertEquals(1, store.entries(other).size)
        assertEquals(2, store.entries(profile, BookmarkScope.ALL).size)
        assertEquals("Plov", assertNotNull(store.bookmark("https://example.org/pilaf", other)).title)
    }

    @Test
    fun removingTakesTheRowThePassagesAndTheFile() {
        val saved = store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")
        val file = assertNotNull(store.fileOf(saved))

        store.remove(saved.id)

        assertNull(store.bookmark(saved.id))
        assertTrue(store.chunks(saved.id).isEmpty(), "the passages outlived the bookmark")
        assertFalse(file.exists(), "the readable copy was left behind")
    }

    // MARK: Searching

    @Test
    fun aWordInTheTitleFindsIt() {
        store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")
        store.save(
            page(title = "Borscht", excerpt = "A soup.", text = "Borscht is a beet soup."),
            "https://example.org/borscht",
            "f",
            profile,
            "Personal",
        )

        val hits = store.search("pilaf", profile)
        assertEquals(1, hits.size)
        assertEquals("Pilaf", hits.first().bookmark.title)
    }

    /** Found by something the page said, and answered with the sentence that said it. */
    @Test
    fun aWordOnlyInTheTextFindsItThroughThePassages() {
        store.save(
            page(text = "Pilaf is a rice dish.\n\nIt is traditionally cooked in a cauldron called a kazan."),
            "https://example.org/pilaf",
            "fallback",
            profile,
            "Personal",
        )

        val hits = store.search("cauldron", profile)
        assertEquals(1, hits.size)
        assertContains(hits.first().snippet, "cauldron")
    }

    /** Every word of three letters or more has to be there; a stray short one must not count. */
    @Test
    fun everyLongWordHasToMatch() {
        store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")

        assertEquals(1, store.search("pilaf rice", profile).size)
        assertEquals(0, store.search("pilaf borscht", profile).size)
        // "in" is under three letters: it is not a requirement, so this still matches on "pilaf".
        assertEquals(1, store.search("pilaf in", profile).size)
    }

    @Test
    fun anEmptyQueryIsJustTheList() {
        store.save(page(), "https://example.org/pilaf", "fallback", profile, "Personal")
        store.save(
            page(title = "Borscht", text = "Borscht is a beet soup."),
            "https://example.org/borscht",
            "f",
            profile,
            "Personal",
        )

        assertEquals(2, store.search("", profile).size)
        assertEquals(2, store.search("  ", profile).size)
    }
}
