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

    /**
     * The profile's cookies, local storage and caches — the logins.
     *
     * The Mac's "Clear History and Site Data" clears the `WKWebsiteDataStore`; here it is the same
     * two things the platform exposes per profile. Anything holding an open page in this profile
     * will find itself signed out, which is what the dialog says will happen.
     */
    fun clearSiteData(storeName: String?) {
        if (storeName == null || !isSupported) return
        runCatching {
            val profile = ProfileStore.getInstance().getOrCreateProfile(storeName)
            profile.cookieManager.removeAllCookies(null)
            profile.cookieManager.flush()
            profile.webStorage.deleteAllData()
        }
    }

    /**
     * Ends a private profile by deleting its store outright.
     *
     * The Mac gets this for nothing: a private profile is a `WKWebsiteDataStore.nonPersistent()`, so
     * closing it *is* forgetting it. `androidx.webkit` has no ephemeral profile — every one of them
     * is on disk — so the promise has to be kept by hand, and kept even when the app is killed
     * before it can. That is why [deleteOrphanedPrivateStores] exists and runs at launch.
     */
    fun deletePrivateStore(storeName: String?) {
        if (storeName == null || !isSupported) return
        runCatching {
            // Data first, then the profile: a delete that fails half-way should fail having removed
            // the cookies rather than having kept them under a name nothing points at any more.
            clearSiteData(storeName)
            ProfileStore.getInstance().deleteProfile(storeName)
        }
    }

    /**
     * Stores left behind by a private session the app did not outlive.
     *
     * A private profile is never written to `state.json`, so after a kill there is nothing left that
     * knows the store existed — except the engine, which still has it. Anything the engine holds and
     * six does not is either that, or a profile deleted on another device; both should go.
     */
    fun deleteOrphanedPrivateStores(profiles: List<Profile>) {
        for (name in orphanedStores(profiles)) deletePrivateStore(name)
    }

    /** The platform's own, which exists whether or not six ever asks for it. */
    const val DEFAULT_PROFILE_NAME = "Default"
}
