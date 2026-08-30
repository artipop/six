package org.deffun.six.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.util.LruCache
import android.webkit.WebView
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.ByteArrayOutputStream
import java.util.UUID
import org.deffun.six.core.ThumbnailStore

/**
 * Drawing a page, keeping the picture, and handing it back to a card.
 *
 * ## Why 400 pixels wide
 *
 * The Mac's number, and its reasoning, unchanged: a card is never drawn bigger than a column and in
 * the overview it is drawn at a fraction of one, so anything wider is detail nobody sees. "Every
 * point here is a megabyte over a strip's worth of windows" — a strip of a hundred is exactly the
 * shape this feature is for, and the width is the only thing standing between it and a hundred
 * full-resolution screens.
 *
 * ## What is in memory, and what is not
 *
 * The pictures live on disk. What is held here is a small, byte-bounded cache of the decoded ones,
 * because a card that scrolls back into view should not go to disk again — and because a bound
 * measured in bytes is the only kind that means anything when the things being counted are bitmaps.
 */
class PageThumbnails(private val store: ThumbnailStore) {

    /** Bitmaps, decoded, bounded by what they actually weigh rather than by how many there are. */
    private val decoded = object : LruCache<UUID, ImageBitmap>(CACHE_BYTES) {
        override fun sizeOf(key: UUID, value: ImageBitmap): Int = value.width * value.height * 4
    }

    /**
     * Draws what the page has already rendered.
     *
     * Called as a column is discarded, which is the last moment the picture exists — and the reason
     * nothing here waits for a fresh frame: a window on its way off the strip will never get another
     * one, and asking for one returns nothing.
     *
     * `WebView.draw` is a software redraw of the view, not the engine's own snapshot API, which the
     * Mac has and this platform does not. Composited content a page hands to the GPU — a playing
     * video, some canvas — can come back missing. That is a picture of a page with a hole in it
     * rather than a wrong picture, and it is what the platform offers.
     */
    fun capture(webView: WebView): Bitmap? {
        val width = webView.width
        val height = webView.height
        if (width <= 0 || height <= 0) return null

        val scale = minOf(1f, WIDTH.toFloat() / width)
        val bitmap = runCatching {
            Bitmap.createBitmap(
                (width * scale).toInt().coerceAtLeast(1),
                (height * scale).toInt().coerceAtLeast(1),
                Bitmap.Config.ARGB_8888,
            )
        }.getOrNull() ?: return null

        return try {
            val canvas = Canvas(bitmap)
            canvas.scale(scale, scale)
            webView.draw(canvas)
            bitmap
        } catch (error: Throwable) {
            bitmap.recycle()
            null
        }
    }

    /**
     * Encodes the picture, files it, and frees the bitmap. Takes ownership: nothing may draw it or
     * read it after this.
     *
     * Split from [capture] because only the drawing has to happen on the main thread — the view is
     * there and nowhere else — while encoding a PNG is tens of milliseconds of work at exactly the
     * moment a column is sliding off the strip. Doing both where the view is would put that hitch
     * into every discard.
     */
    fun write(id: UUID, bitmap: Bitmap) {
        try {
            val bytes = ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray()
            }
            decoded.remove(id)
            store.write(bytes, id)
        } catch (error: Throwable) {
            // A picture that could not be encoded is a card without one, and nothing more.
        } finally {
            // Freed here rather than left to the collector: this is the one allocation in the app
            // whose size is measured in screens.
            bitmap.recycle()
        }
    }

    /**
     * The picture of a window, decoded. Disk work — the caller keeps it off the main thread.
     *
     * A cache miss for a window that has no picture costs one lookup and no more: the store
     * remembers which those were.
     */
    fun read(id: UUID): ImageBitmap? {
        decoded[id]?.let { return it }
        val bytes = store.read(id) ?: return null
        val bitmap = runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
            ?: return null
        val image = bitmap.asImageBitmap()
        decoded.put(id, image)
        return image
    }

    fun remove(id: UUID) {
        decoded.remove(id)
        store.remove(id)
    }

    /** The strip is what bounds the folder: everything else is a picture of a window that is gone. */
    fun prune(keeping: Set<UUID>) {
        store.prune(keeping)
        for (id in decoded.snapshot().keys - keeping) decoded.remove(id)
    }

    private companion object {
        const val WIDTH = 400

        /** Four megabytes: about ten cards at this width, which is more than are ever on screen. */
        const val CACHE_BYTES = 4 * 1024 * 1024
    }
}
