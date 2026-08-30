package org.deffun.six.app

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

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
    url: String,
    onPageStarted: (String) -> Unit,
    onTitleChanged: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
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

                loadUrl(url)
            }
        },
        update = { webView ->
            // Only navigate when the address actually changed: `update` runs on every recomposition,
            // and reloading a page because a title arrived would be an endless loop with a network
            // bill attached.
            if (webView.url != url) webView.loadUrl(url)
        },
        onRelease = { it.destroy() },
    )
}
