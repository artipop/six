package org.deffun.six.app

import android.webkit.WebView
import java.util.UUID

/**
 * The `WebView` currently backing each column, by tab.
 *
 * Compose does not hand a composable's `AndroidView` back to anyone else, and two things outside the
 * column need the view itself: the system back gesture, which must walk the page's history before it
 * walks out of the app, and — later — discarding a column and restoring it from a `Bundle`, which is
 * this platform's answer to `LivePageCache`.
 *
 * Registration is the view's own lifecycle: it appears in `factory` and leaves in `onRelease`, so a
 * destroyed `WebView` is never in here to be called.
 */
object LivePages {

    private val pages = mutableMapOf<UUID, WebView>()

    fun register(tabId: UUID, webView: WebView) {
        pages[tabId] = webView
    }

    fun unregister(tabId: UUID) {
        pages.remove(tabId)
    }

    operator fun get(tabId: UUID): WebView? = pages[tabId]

    /** True when the page took the gesture, so the app should not. */
    fun goBack(tabId: UUID?): Boolean {
        val page = tabId?.let { pages[it] } ?: return false
        if (!page.canGoBack()) return false
        page.goBack()
        return true
    }
}
