package org.deffun.six.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The extraction script, against the Mac's own copy of it.
 *
 * `readable-page.js` decides the shape of every bookmark's text: what counts as the content, what is
 * navigation, how the DOM becomes Markdown. Changed on one side only, the same page saved on two
 * devices becomes two different documents — different Markdown in the folder, different passages in
 * the table, and, once there are vectors, different vectors.
 *
 * It cannot be shared as a file: the Swift source is not something a Gradle build reads at runtime,
 * and the two front ends are built by different toolchains. So it is a copy, and this is the thing
 * that stops the copy from rotting quietly.
 */
class ReadablePageScriptTest {

    /** `android/core` is the working directory of this test; the Mac's tree is two levels up. */
    private val swiftSource = File("../../six/Bookmarks/ReadablePage.swift")

    private fun scriptFromSwift(): String {
        val source = swiftSource.readText()
        val opening = "static let script = #\"\"\""
        val start = source.indexOf(opening)
        assertTrue(start >= 0, "the Swift literal has moved or been renamed")
        val body = source.substring(start + opening.length)
        val end = body.indexOf("\"\"\"#")
        assertTrue(end >= 0, "the Swift literal is not closed where expected")

        val lines = body.substring(0, end).trim('\n').lines()
        // Swift indents the literal's body; the copy is stored unindented.
        val indent = lines.filter { it.isNotBlank() }.minOfOrNull { it.takeWhile(Char::isWhitespace).length } ?: 0
        return lines.joinToString("\n") { if (it.isBlank()) "" else it.substring(indent) }
    }

    @Test
    fun theCopyIsStillTheMacs() {
        assertTrue(
            swiftSource.isFile,
            "ReadablePage.swift is not where this test expects it: ${swiftSource.absolutePath}",
        )

        // Trailing whitespace is compared away on both sides: the Swift literal ends with the
        // indentation in front of its closing delimiter, and a blank line at the end of a function
        // body is not a difference worth failing over.
        assertEquals(
            scriptFromSwift().trimEnd(),
            ReadablePage.script.trimEnd(),
            "readable-page.js has drifted from ReadablePage.swift. Copy the Swift literal across " +
                "deliberately — a page saved on two devices has to be the same document.",
        )
    }

    /**
     * And that the copy is the thing actually being run, rather than a resource that failed to load
     * into an empty string nobody noticed.
     */
    @Test
    fun theScriptIsLoadedAndLooksLikeItself() {
        val script = ReadablePage.script
        assertTrue(script.length > 4000, "the script is suspiciously short: ${script.length} characters")
        assertTrue(script.contains("function pickRoot()"), "the content-finding half is missing")
        assertTrue(script.contains("markdown: markdown.slice"), "the script does not return a result")
    }
}
