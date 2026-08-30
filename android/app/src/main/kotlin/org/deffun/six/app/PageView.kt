package org.deffun.six.app

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import java.util.UUID

/**
 * One page, in one column.
 *
 * The Mac's `WebPage` and this are the same thing wearing different frameworks, and the mapping is
 * in [docs/android.md]. What matters here is what the strip needs from it and nothing more: an
 * address, a title, and the navigations that make history.
 *
 * **Gestures inside the page are the page's.** This view takes no pointer input of its own, so a
 * scroll here scrolls the page and only the handle above moves the strip. That is the whole reason
 * the phone's gesture model was designed the way it was — a `WebView` inside a pannable container
 * otherwise fights for every touch.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PageView(
    tabId: UUID,
    url: String,
    profileStoreName: String?,
    onPageStarted: (String) -> Unit,
    onTitleChanged: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Keyed on the profile: a WebView cannot be moved between profiles once it has been used, so a
    // column whose profile changes has to become a different view rather than a reconfigured one.
    // What this view was last told to load. Deliberately not Compose state: it is bookkeeping for
    // the view, and making it state would invalidate the composition that just wrote it.
    val requested = remember(profileStoreName) { arrayOfNulls<String>(1) }

    key(profileStoreName) {
        AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                // Before any setting, any client and above all before `loadUrl`: the point of the
                // profile is that no request is ever made against the wrong cookie jar.
                WebProfiles.attach(this, profileStoreName)

                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                // A browser is what this is; the default is a WebView pretending to be an app.
                settings.setSupportMultipleWindows(true)
                settings.mediaPlaybackRequiresUserGesture = false

                webViewClient = object : WebViewClient() {
                    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                        onPageStarted(url)
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onReceivedTitle(view: WebView, title: String?) {
                        onTitleChanged(title.orEmpty())
                    }
                }

                requested[0] = url
                LivePages.register(tabId, this)
                loadUrl(url)
            }
        },
        update = { webView ->
            // Compared against what we last asked for, never against `webView.url`.
            //
            // The page's own address is not the one we requested: a redirect changes it, and so does
            // a server that merely adds a trailing slash. Comparing with it would find a mismatch
            // immediately after every successful load, request the original again, be redirected
            // again — a reload loop that never settles and never stops making requests.
            if (requested[0] != url) {
                requested[0] = url
                webView.loadUrl(url)
            }
        },
        onRelease = {
            LivePages.unregister(tabId)
            it.destroy()
        },
        )
    }
}
