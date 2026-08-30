package org.deffun.six.core

import kotlinx.serialization.Serializable

/**
 * The page as something a person can read: the main content as Markdown, plus the metadata a
 * bookmark keeps.
 *
 * Extracted in the page itself, Readability-style — `<article>` / `<main>` when the page says where
 * the content is, otherwise the element holding the most paragraph text; navigation, asides,
 * footers, forms and hidden nodes dropped; headings, lists, quotes, code, links, tables and large
 * images surviving the conversion.
 *
 * ## The script is a copy, and the copy is checked
 *
 * `readable-page.js` is `ReadablePage.script` from the Mac, character for character. It has to be a
 * copy — the Swift file is not something a Gradle build can read at runtime, and the two front ends
 * are built by different toolchains — so `ReadablePageScriptTest` reads the Swift source and fails
 * when they drift. That turns "remember to copy it across" into something that cannot be forgotten
 * quietly, which is the same trick the golden geometry table plays.
 *
 * The extraction is the shape of every bookmark's text: change it on one side only and the same page
 * saved on two devices is two different documents.
 */
@Serializable
data class ReadablePage(
    val title: String = "",
    val byline: String = "",
    val siteName: String = "",
    val excerpt: String = "",
    val image: String = "",
    val language: String = "",
    val markdown: String = "",
    val text: String = "",
) {
    val imageUrl: String? get() = image.ifEmpty { null }

    companion object {
        /** Runs as a function body in the page. Read-only: nothing in the DOM is touched. */
        val script: String by lazy {
            checkNotNull(ReadablePage::class.java.getResourceAsStream("/readable-page.js")) {
                "readable-page.js is missing from the module's resources"
            }.bufferedReader().readText()
        }

        /**
         * What comes back from the page, tidied the way the Mac tidies it.
         *
         * Null when there is nothing to save. A page with no readable text is not an error to report
         * — it is a page that cannot be bookmarked, and saying so is the caller's business.
         */
        fun from(json: String): ReadablePage? {
            val page = runCatching {
                SnapshotJson.decodeFromString(serializer(), json)
            }.getOrNull() ?: return null
            val tidied = page.copy(markdown = page.markdown.trim(), text = page.text.trim())
            return if (tidied.text.isEmpty()) null else tidied
        }
    }
}
