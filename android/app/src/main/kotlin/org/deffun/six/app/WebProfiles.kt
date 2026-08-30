package org.deffun.six.app

import android.webkit.WebView
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.deffun.six.core.Profile

/**
 * six's profiles, on the engine.
 *
 * A profile is the isolation: its own cookies, its own logins, its own storage. On the Mac that is a
 * `WKWebsiteDataStore(forIdentifier:)`; here it is an `androidx.webkit.Profile`, reached by name and
 * attached to a `WebView` before that view is used for anything.
 *
 * ## Why the identifier and not the name
 *
 * The Android profile is named after [Profile.dataStoreId], never after [Profile.name]. six keeps
 * those as two separate fields on purpose: the display name is the user's and can be edited, and
 * deriving the store from it would mean renaming "Work" to "Job" silently signs you out of
 * everything. The identifier never changes, so neither does the store behind it.
 *
 * ## When the device cannot do this
 *
 * Multi-profile arrived in API 34, which is this app's minimum — but the WebView on the device is
 * updated separately from the OS, so the capability is still a runtime question. If the answer is
 * no, every profile would share one cookie jar, which is not a degraded version of six's profiles;
 * it is the opposite of them. So [isSupported] is surfaced rather than swallowed, and a caller that
 * ignores it is choosing to.
 */
object WebProfiles {

    val isSupported: Boolean
        get() = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)

    /** The name of the underlying store for a six profile, or null where the device cannot. */
    fun storeName(profile: Profile): String? =
        if (isSupported) profile.dataStoreId.toString() else null

    /**
     * Attaches a profile to a fresh `WebView`.
     *
     * Must happen before the view loads anything: the platform refuses to move a WebView between
     * profiles once it has been used, and the whole point is that no request is made against the
     * wrong cookie jar first.
     *
     * @return true when the view is on the intended profile.
     */
    fun attach(webView: WebView, storeName: String?): Boolean {
        if (storeName == null || !isSupported) return false
        return runCatching {
            ProfileStore.getInstance().getOrCreateProfile(storeName)
            WebViewCompat.setProfile(webView, storeName)
        }.isSuccess
    }

    /**
     * Profiles the engine is holding that six no longer has — a profile deleted on another device
     * and synced away leaves its cookies behind otherwise.
     *
     * The default store is never in the result: the platform owns it and refuses to delete it.
     */
    fun orphanedStores(profiles: List<Profile>): List<String> {
        if (!isSupported) return emptyList()
        val known = profiles.map { it.dataStoreId.toString() }.toSet()
        return runCatching {
            ProfileStore.getInstance().allProfileNames
                .filter { it != DEFAULT_PROFILE_NAME && it !in known }
        }.getOrDefault(emptyList())
    }

    /** The platform's own, which exists whether or not six ever asks for it. */
    const val DEFAULT_PROFILE_NAME = "Default"
}
