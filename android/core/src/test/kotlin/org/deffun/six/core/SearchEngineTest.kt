package org.deffun.six.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What typing into the address field does, which has to be the same sentence on both platforms.
 *
 * These are small rules, and that is the danger: they look obvious enough to reimplement by eye, and
 * a browser where the same typing goes somewhere else is a different browser.
 */
class SearchEngineTest {

    // MARK: The setting

    /**
     * The stored ids are Swift's `rawValue`s. An engine chosen on the Mac and read here is only the
     * same engine because these two strings match, so they are asserted rather than derived.
     */
    @Test
    fun theStoredIdsAreTheMacs() {
        assertEquals("duckDuckGo", SearchEngine.DUCK_DUCK_GO.id)
        assertEquals("google", SearchEngine.GOOGLE.id)
        assertEquals(SearchEngine.DUCK_DUCK_GO, SearchEngine.from("duckDuckGo"))
        assertEquals(SearchEngine.GOOGLE, SearchEngine.from("google"))
    }

    /** An unset or unknown setting is DuckDuckGo, not a crash and not Google. */
    @Test
    fun anUnknownSettingFallsBackToTheDefault() {
        assertEquals(SearchEngine.DUCK_DUCK_GO, SearchEngine.DEFAULT)
        assertEquals(SearchEngine.DUCK_DUCK_GO, SearchEngine.from(null))
        assertEquals(SearchEngine.DUCK_DUCK_GO, SearchEngine.from(""))
        assertEquals(SearchEngine.DUCK_DUCK_GO, SearchEngine.from("kagi"))
    }

    // MARK: Building a search

    @Test
    fun aSearchGoesWhereTheMacSendsIt() {
        assertEquals("https://duckduckgo.com/?q=pilaf", SearchEngine.DUCK_DUCK_GO.searchUrl("pilaf"))
        assertEquals("https://www.google.com/search?q=pilaf", SearchEngine.GOOGLE.searchUrl("pilaf"))
    }

    /**
     * Space is `%20`. `URLEncoder` would write `+`, which every engine accepts and which does not
     * match what the Mac writes — and the same search recorded two ways is two rows in one history.
     */
    @Test
    fun aSpaceIsPercentTwentyAndNotAPlus() {
        val url = SearchEngine.DUCK_DUCK_GO.searchUrl("apple tv")
        assertEquals("https://duckduckgo.com/?q=apple%20tv", url)
        assertFalse(url.contains('+'))
    }

    @Test
    fun cyrillicSurvivesTheRoundTrip() {
        val query = "плов рецепт"
        val url = SearchEngine.DUCK_DUCK_GO.searchUrl(query)
        assertEquals(query, SearchEngine.DUCK_DUCK_GO.query(url))
    }

    // MARK: Recognising a results page

    @Test
    fun aResultsPageIsRecognisedByItsOwnEngineOnly() {
        val duck = "https://duckduckgo.com/?q=pilaf&ia=web"
        assertEquals("pilaf", SearchEngine.DUCK_DUCK_GO.query(duck))
        assertNull(SearchEngine.GOOGLE.query(duck))

        val google = "https://www.google.com/search?q=pilaf&hl=en"
        assertEquals("pilaf", SearchEngine.GOOGLE.query(google))
        assertNull(SearchEngine.DUCK_DUCK_GO.query(google))

        val (engine, query) = assertNotNull(SearchEngine.search(google))
        assertEquals(SearchEngine.GOOGLE, engine)
        assertEquals("pilaf", query)
    }

    /** Google's rule is the path as well as the host: its home page is not a results page. */
    @Test
    fun onlyTheRightHostAndPathCount() {
        assertEquals("x", SearchEngine.DUCK_DUCK_GO.query("https://html.duckduckgo.com/?q=x"))
        assertNull(SearchEngine.DUCK_DUCK_GO.query("https://notduckduckgo.com/?q=x"))
        assertNull(SearchEngine.GOOGLE.query("https://www.google.com/?q=x"))
        assertNull(SearchEngine.GOOGLE.query("https://www.google.com/maps?q=x"))
        assertNull(SearchEngine.DUCK_DUCK_GO.query("https://duckduckgo.com/?q="))
        assertNull(SearchEngine.search("https://example.org/?q=x"))
        // Not a URL at all, and not a crash either.
        assertNull(SearchEngine.search("not a url"))
    }

    // MARK: Address or query

    @Test
    fun aRecognisedSchemeIsAnAddress() {
        for (text in listOf("https://example.org", "http://example.org", "file:///tmp/x.html", "about:blank")) {
            assertTrue(UserInput.looksLikeAddress(text), text)
            assertEquals(text, UserInput.url(text), text)
        }
    }

    @Test
    fun aSchemelessHostGetsHttps() {
        assertEquals("https://example.org", UserInput.url("example.org"))
        assertEquals("https://localhost:8080", UserInput.url("localhost:8080"))
        assertTrue(UserInput.looksLikeAddress("example.org"))
        assertTrue(UserInput.looksLikeAddress("localhost"))
    }

    @Test
    fun anythingElseIsASearch() {
        assertEquals(
            SearchEngine.DUCK_DUCK_GO.searchUrl("what is pilaf"),
            UserInput.url("what is pilaf"),
        )
        assertFalse(UserInput.looksLikeAddress("what is pilaf"))
        // A dot is not enough when there are spaces around it: this is a sentence.
        assertFalse(UserInput.looksLikeAddress("pilaf. recipe"))
    }

    @Test
    fun theEngineTheSearchGoesToIsTheOnePassedIn() {
        assertEquals(
            "https://www.google.com/search?q=pilaf",
            UserInput.url("pilaf", SearchEngine.GOOGLE),
        )
    }

    @Test
    fun nothingTypedIsNothingToLoad() {
        assertNull(UserInput.url(""))
        assertNull(UserInput.url("   "))
        assertFalse(UserInput.looksLikeAddress(""))
        assertFalse(UserInput.looksLikeAddress("   "))
    }

    /** Input is trimmed before anything else looks at it, on both platforms. */
    @Test
    fun surroundingSpaceIsIgnored() {
        assertEquals("https://example.org", UserInput.url("  https://example.org  "))
        assertTrue(UserInput.looksLikeAddress("  example.org  "))
    }
}
