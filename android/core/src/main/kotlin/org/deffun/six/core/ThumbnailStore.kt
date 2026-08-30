package org.deffun.six.core

import java.io.File
import java.util.UUID

/**
 * The pictures of the pages, on disk — one PNG per window, named by its id.
 *
 * A picture outlives the page it was taken of, which is the whole point of discarding columns, and
 * it should outlive the launch too: coming back to a strip and finding a wall of blank cards is
 * exactly the moment the pictures were for. Every browser that shows thumbnails keeps them as files
 * — Firefox's `moz-page-thumbnails`, Safari's snapshots under Caches — for the same reason.
 *
 * Read back lazily, never all at once: a strip of a hundred windows is a hundred files nobody has
 * looked at yet. What bounds the folder is the strip itself — [prune] throws away the pictures of
 * windows that no longer exist.
 *
 * The file name is the Mac's, uppercase UUID and all, so the same folder means the same thing on
 * either side of it.
 */
class ThumbnailStore(private val folder: File) {

    /**
     * Windows looked up and found to have no picture, so a window that never had one is not looked
     * for again every time a card appears.
     */
    private val missing = mutableSetOf<UUID>()

    fun file(id: UUID): File = File(folder, "${id.toString().uppercase()}.png")

    /** Keeps the PNG. The caller does this off the main thread; nobody is waiting for it. */
    fun write(bytes: ByteArray, id: UUID) {
        synchronized(missing) { missing.remove(id) }
        runCatching {
            folder.mkdirs()
            val temporary = File(folder, "${id.toString().uppercase()}.png.new")
            temporary.writeBytes(bytes)
            if (!temporary.renameTo(file(id))) {
                file(id).delete()
                if (!temporary.renameTo(file(id))) temporary.delete()
            }
        }
    }

    /**
     * The picture of a window, if there is one. Null the second time it is asked for a window that
     * has none — the lookup is a disk hit, and a window without a picture keeps not having one.
     */
    fun read(id: UUID): ByteArray? {
        if (synchronized(missing) { id in missing }) return null
        val bytes = runCatching { file(id).takeIf { it.isFile }?.readBytes() }.getOrNull()
        if (bytes == null || bytes.isEmpty()) {
            synchronized(missing) { missing.add(id) }
            return null
        }
        return bytes
    }

    fun remove(id: UUID) {
        synchronized(missing) { missing.add(id) }
        runCatching { file(id).delete() }
    }

    /**
     * Drops the pictures of windows that are gone — closed while the app was not running, or closed
     * in a launch that never got to clean up.
     *
     * Anything that is not a picture of a live window is litter, including the half-written
     * temporaries a kill can leave behind.
     */
    fun prune(keeping: Set<UUID>) {
        val names = keeping.map { "${it.toString().uppercase()}.png" }.toSet()
        runCatching {
            folder.listFiles()?.forEach { file ->
                if (file.name !in names) file.delete()
            }
        }
        synchronized(missing) { missing.retainAll(keeping) }
    }
}
