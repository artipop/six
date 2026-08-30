package org.deffun.six.core

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The pictures of the pages: named the Mac's way, read lazily, and bounded by the strip. */
class ThumbnailStoreTest {

    private val folder: File = Files.createTempDirectory("six-thumbnails").toFile()
    private val store = ThumbnailStore(folder)
    private val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte())

    @AfterTest
    fun cleanUp() {
        folder.deleteRecursively()
    }

    /** `<UUID>.png`, uppercase, so one folder means the same thing on either side of it. */
    @Test
    fun theFileNameIsTheMacs() {
        val id = UUID.fromString("ed2fced9-98a6-4f1a-b360-3bd6d9887847")
        assertEquals("ED2FCED9-98A6-4F1A-B360-3BD6D9887847.png", store.file(id).name)
    }

    @Test
    fun aPictureSurvivesBeingWrittenAndRead() {
        val id = UUID.randomUUID()
        store.write(png, id)

        assertContentEquals(png, store.read(id))
        assertFalse(File(folder, "${id.toString().uppercase()}.png.new").exists(), "a temporary was left")
    }

    @Test
    fun aWindowWithNoPictureReadsAsNothing() {
        assertNull(store.read(UUID.randomUUID()))
    }

    /**
     * And keeps reading as nothing without going back to disk. A card appearing is a common event
     * and a window that never had a picture keeps not having one.
     */
    @Test
    fun aMissingPictureIsNotLookedForTwice() {
        val id = UUID.randomUUID()
        assertNull(store.read(id))

        // Written behind the store's back: it has already decided there is nothing there.
        folder.mkdirs()
        store.file(id).writeBytes(png)
        assertNull(store.read(id), "the store went back to disk for a window it knew had none")

        // Until something writes through it, which is what clears that memory.
        store.write(png, id)
        assertContentEquals(png, store.read(id))
    }

    @Test
    fun writingOverAPictureReplacesIt() {
        val id = UUID.randomUUID()
        store.write(png, id)
        store.write(byteArrayOf(1, 2, 3), id)

        assertContentEquals(byteArrayOf(1, 2, 3), store.read(id))
    }

    @Test
    fun removingTakesTheFile() {
        val id = UUID.randomUUID()
        store.write(png, id)
        store.remove(id)

        assertFalse(store.file(id).exists())
        assertNull(store.read(id))
    }

    /** What bounds the folder is the strip: anything that is not a live window's picture is litter. */
    @Test
    fun pruningKeepsOnlyTheWindowsThatStillExist() {
        val kept = UUID.randomUUID()
        val gone = UUID.randomUUID()
        store.write(png, kept)
        store.write(png, gone)
        // What a kill can leave behind.
        File(folder, "half-written.png.new").writeBytes(png)

        store.prune(keeping = setOf(kept))

        assertTrue(store.file(kept).exists())
        assertFalse(store.file(gone).exists())
        assertFalse(File(folder, "half-written.png.new").exists(), "a temporary survived the prune")
    }

    /** A prune must not leave the store believing a surviving window has no picture. */
    @Test
    fun pruningForgetsOnlyWhatItRemoved() {
        val kept = UUID.randomUUID()
        val gone = UUID.randomUUID()
        assertNull(store.read(gone)) // remembered as missing
        store.write(png, kept)

        store.prune(keeping = setOf(kept))

        assertContentEquals(png, store.read(kept))
    }
}
