package org.deffun.six.app

import org.deffun.six.R

/**
 * Why a page could not be saved.
 *
 * Keys rather than sentences: the view resolves them against `strings.xml`, so nothing that a person
 * reads is decided in a view model. The Mac throws a `Failure` carrying a localised string; the split
 * is the same one, drawn one step earlier.
 */
object BookmarkNotice {
    const val NOTHING_LOADED = "nothing_loaded"
    const val NO_TEXT = "no_text"
    const val PRIVATE = "private"
    const val FAILED = "failed"

    fun stringId(notice: String): Int = when (notice) {
        NOTHING_LOADED -> R.string.bookmark_nothing_loaded
        NO_TEXT -> R.string.bookmark_no_text
        PRIVATE -> R.string.bookmark_private
        else -> R.string.bookmark_failed
    }
}
