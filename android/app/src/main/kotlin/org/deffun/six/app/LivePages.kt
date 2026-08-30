package org.deffun.six.app

import android.os.Bundle
import android.webkit.WebView
import java.util.UUID

/**
 * Which columns have a real `WebView`, and what is kept of the ones that do not.
 *
 * A window is not a page it holds forever. On the Mac a `WebPage` is a content process, so a strip
 * of a hundred windows keeps only as many live as the machine can carry and *discards* the rest —
 * the window stays where it is, with its address, its history and its scroll offset, and builds the
 * page again when you come back to it. [NiriLayout.visibleTabIds] decides which those are.
 *
 * Android has no process per tab, but a `WebView` is not cheap either, and the platform's answer to
 * "keep this window without keeping its page" is `saveState`/`restoreState` into a `Bundle`.
 *
 * ## The part that is not verified
 *
 * `saveState` documents the back/forward list. Whether it also brings back the scroll offset — which
 * is what makes returning to a column feel like returning rather than reloading — is the claim
 * docs/android.md flags as the one most likely to be half-true, and nothing here can settle it
 * without a device. The code is written as if it does; if it does not, this is where the answer goes.
 */
object LivePages {

    private val live = mutableMapOf<UUID, WebView>()
    private val discarded = mutableMapOf<UUID, Bundle>()

    /** A view has been built for this column. */
    fun register(tabId: UUID, webView: WebView) {
        live[tabId] = webView
    }

    /**
     * The column is going away. Its page is kept as a bundle so coming back is a restore rather than
     * a fresh request — the case the whole design is tuned for.
     */
    fun discard(tabId: UUID, webView: WebView) {
        val state = Bundle()
        // `saveState` returns null when there is nothing worth keeping — a view that never loaded.
        if (webView.saveState(state) != null) discarded[tabId] = state
        live.remove(tabId)
    }

    /**
     * Puts a rebuilt view back where its column was, if there is anything to put back.
     *
     * @return true when the view was restored and must not be sent to load the address again.
     */
    fun restore(tabId: UUID, webView: WebView): Boolean {
        val state = discarded[tabId] ?: return false
        val restored = webView.restoreState(state) != null
        if (restored) discarded.remove(tabId)
        return restored
    }

    /**
     * Throws away what was kept of a column's page.
     *
     * Called when the address changes under it: a bundle restored after that would quietly navigate
     * back to the page the column used to be on, which looks like the address bar not working.
     */
    fun forget(tabId: UUID) {
        live.remove(tabId)
        discarded.remove(tabId)
    }

    operator fun get(tabId: UUID): WebView? = live[tabId]

    /** True when the page took the gesture, so the app should not. */
    fun goBack(tabId: UUID?): Boolean {
        val page = tabId?.let { live[it] } ?: return false
        if (!page.canGoBack()) return false
        page.goBack()
        return true
    }

    /**
     * Memory pressure is not answered from here.
     *
     * The obvious version of that — walk the live views and save their state — would save the state
     * of views still on screen and still in the composition, which is not discarding anything. On
     * this platform a page is released by the *composition* dropping it, so the answer belongs where
     * the live set is decided: `SixViewModel.onMemoryPressure` narrows it, Compose releases what
     * fell out, and each one arrives here through `discard` in its own `onRelease`.
     */
}
