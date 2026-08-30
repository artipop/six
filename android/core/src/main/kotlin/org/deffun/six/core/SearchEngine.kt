package org.deffun.six.core

import java.net.URI
import java.net.URLEncoder

/**
 * Where a query goes, and how the address field tells one from an address.
 *
 * [id] is the string the `settings` table holds, and it is the Swift enum's `rawValue` rather than
 * anything idiomatic here: a search engine chosen on the Mac and read on the phone has to be the
 * same engine, and the only thing carrying that across is this string.
 */
enum class SearchEngine(val id: String, val title: String) {
    DUCK_DUCK_GO("duckDuckGo", "DuckDuckGo"),
    GOOGLE("google", "Google"),
    ;

    fun searchUrl(query: String): String = when (this) {
        DUCK_DUCK_GO -> "https://duckduckgo.com/?q=${encode(query)}"
        GOOGLE -> "https://www.google.com/search?q=${encode(query)}"
    }

    /**
     * The query behind one of this engine's results pages, if that is what this is — so history can
     * show "пилав · DuckDuckGo Search" rather than the results page's own title.
     */
    fun query(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        val host = uri.host?.lowercase() ?: return null
        val q = queryParameter(uri.rawQuery, "q")?.takeIf { it.isNotEmpty() } ?: return null
        return when (this) {
            DUCK_DUCK_GO -> if (host == "duckduckgo.com" || host.endsWith(".duckduckgo.com")) q else null
            GOOGLE -> if (host.startsWith("www.google.") && uri.path == "/search") q else null
        }
    }

    companion object {
        /** What six searches with until the settings table says otherwise. */
        val DEFAULT = DUCK_DUCK_GO

        fun from(id: String?): SearchEngine = entries.firstOrNull { it.id == id } ?: DEFAULT

        /** Whichever engine's results page this is. */
        fun search(from: String): Pair<SearchEngine, String>? {
            for (engine in entries) {
                val query = engine.query(from) ?: continue
                return engine to query
            }
            return null
        }

        /**
         * Space is `%20`, not `+`.
         *
         * `URLEncoder` writes a form-encoded `+`, which every engine happens to accept and which
         * then does not match what `URLComponents` produces on the Mac. Two front ends writing the
         * same search as two different addresses is two rows in one history.
         */
        private fun encode(value: String): String =
            URLEncoder.encode(value, Charsets.UTF_8).replace("+", "%20")

        private fun decode(value: String): String =
            runCatching { java.net.URLDecoder.decode(value, Charsets.UTF_8) }.getOrDefault(value)

        private fun queryParameter(rawQuery: String?, name: String): String? =
            rawQuery
                ?.split('&')
                ?.firstNotNullOfOrNull { pair ->
                    val separator = pair.indexOf('=')
                    if (separator <= 0 || pair.substring(0, separator) != name) null
                    else decode(pair.substring(separator + 1))
                }
    }
}

/**
 * Address-bar input, turned into something to load.
 *
 * The rule is the Mac's, in `URL.fromUserInput`: a recognised scheme is an address, a scheme-less
 * thing that could be a host gets `https://`, and everything else is a search. It is small enough to
 * look obvious and specific enough that reimplementing it by eye on a second platform would produce
 * a browser where the same typing does different things.
 */
object UserInput {

    private val ADDRESS_SCHEMES = setOf("http", "https", "file", "about")

    /** What to load for what was typed, or null if nothing was. */
    fun url(raw: String, engine: SearchEngine = SearchEngine.DEFAULT): String? {
        val text = raw.trim()
        if (text.isEmpty()) return null

        val scheme = runCatching { URI(text).scheme }.getOrNull()?.lowercase()
        if (scheme in ADDRESS_SCHEMES) return text

        if (looksLikeHost(text)) return "https://$text"

        return engine.searchUrl(text)
    }

    /** Does this look like something to open rather than something to search for? */
    fun looksLikeAddress(raw: String): Boolean {
        val text = raw.trim()
        if (text.isEmpty() || text.contains(' ')) return false
        val scheme = runCatching { URI(text).scheme }.getOrNull()?.lowercase()
        if (scheme in ADDRESS_SCHEMES) return true
        return text.contains('.') || text.startsWith("localhost")
    }

    private fun looksLikeHost(text: String): Boolean =
        !text.contains(' ') && (text.contains('.') || text.startsWith("localhost"))
}

// MARK: - The setting

/**
 * The setting lives in the `settings` table; the knowledge of what its string means lives here,
 * beside the type it means it as — the same split the Mac makes, and the reason [SettingsStore]
 * itself knows only keys and strings.
 *
 * `search.engine` is that table's key, and it is the Mac's. A key invented here would be a setting
 * the other platform never sees change.
 */
var SettingsStore.searchEngine: SearchEngine
    get() = SearchEngine.from(this[SettingsKeys.SEARCH_ENGINE])
    set(value) {
        this[SettingsKeys.SEARCH_ENGINE] = value.id
    }

/** Keys in the shared `settings` table. Only the ones this platform reads or writes. */
object SettingsKeys {
    const val SEARCH_ENGINE = "search.engine"
    const val CENTERS_FOCUS = "layout.centersFocus"
    const val COLUMN_WIDTH = "layout.columnWidth"
    const val DEFAULT_PROFILE = "profile.default"
}
