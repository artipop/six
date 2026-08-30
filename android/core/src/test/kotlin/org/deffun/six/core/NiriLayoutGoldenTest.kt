package org.deffun.six.core

import java.util.UUID
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The numbers, not the intent.
 *
 * [NiriLayoutGeometryTest] is the Mac's suite ported test for test, and it checks that the *rules*
 * hold — N columns of 1/N fill the screen, gaps scale, frames and content width agree. Two
 * implementations can satisfy every one of those rules and still lay a strip out differently, and
 * that failure is silent: the strip simply loses its place when the same `state.json` is opened on
 * the other device.
 *
 * So this reads a table produced by compiling the Mac's own `NiriLayout.swift` and asserts Kotlin
 * computes it to six decimal places. It is the geometry half of the same idea the embedder will need
 * for vectors (docs/android.md) — the contract pinned by values a second implementation has to
 * reproduce, rather than by prose both sides can read differently.
 *
 * A failure here means one of three things, in descending order of likelihood: Kotlin drifted, the
 * layout was deliberately changed on the Mac and the file was not regenerated, or the two languages
 * disagree about arithmetic — rounding at a tie is the one place they genuinely can.
 */
class NiriLayoutGoldenTest {

    private data class Case(
        val name: String,
        val viewport: Size,
        val gap: Double,
        val columnHeight: Double,
        val widths: List<Double>,
        val frames: List<Rect>,
        val contentWidth: Double,
    )

    /** Six decimals is what the generator prints; anything coarser would hide a real divergence. */
    private val tolerance = 1e-6

    private fun assertClose(expected: Double, actual: Double, what: String) {
        assertTrue(
            abs(expected - actual) <= tolerance,
            "$what: golden $expected, computed $actual (Δ ${abs(expected - actual)})",
        )
    }

    private fun goldenCases(): List<Case> {
        val text = checkNotNull(javaClass.getResourceAsStream("/niri-golden.txt")) {
            "niri-golden.txt is missing from the test resources"
        }.bufferedReader().readText()

        val cases = mutableListOf<Case>()
        var name = ""
        var viewport = Size(0.0, 0.0)
        var gap = 0.0
        var columnHeight = 0.0
        var widths = emptyList<Double>()
        var frames = emptyList<Rect>()

        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val parts = line.split(" ")
            when (parts[0]) {
                "case" -> {
                    name = parts[1]
                    viewport = Size(parts[2].toDouble(), parts[3].toDouble())
                }
                "gap" -> gap = parts[1].toDouble()
                "columnHeight" -> columnHeight = parts[1].toDouble()
                "widths" -> widths = parts.drop(1).map { it.toDouble() }
                "frames" -> frames = parts.drop(1).map { spec ->
                    val n = spec.split(",").map { it.toDouble() }
                    Rect(n[0], n[1], n[2], n[3])
                }
                // `contentWidth` closes a case: everything before it has been read.
                "contentWidth" -> cases.add(
                    Case(name, viewport, gap, columnHeight, widths, frames, parts[1].toDouble()),
                )
                else -> error("unexpected line in niri-golden.txt: $line")
            }
        }
        return cases
    }

    /** The frames in the table are for this shape, and the generator uses the same one. */
    private val goldenWidthIndices = listOf(0, 2, 3, 1)

    @Test
    fun kotlinComputesTheMacsGeometry() {
        val cases = goldenCases()
        assertTrue(cases.isNotEmpty(), "the golden table is empty")

        for (case in cases) {
            val layout = NiriLayout().updateViewport(case.viewport)

            assertClose(case.gap, layout.gap, "${case.name} gap")
            assertClose(case.gap, layout.outerGap, "${case.name} outerGap")
            assertClose(case.columnHeight, layout.columnHeight, "${case.name} columnHeight")

            assertEquals(NiriLayout.WIDTH_PRESETS.size, case.widths.size, "${case.name} preset count")
            case.widths.forEachIndexed { index, expected ->
                val actual = layout.width(NiriColumn(UUID.randomUUID(), index))
                assertClose(expected, actual, "${case.name} width[$index]")
            }

            val workspace = NiriWorkspace(
                columns = goldenWidthIndices.map { NiriColumn(UUID.randomUUID(), it) },
            )
            val computed = layout.columnFrames(workspace)
            assertEquals(case.frames.size, computed.size, "${case.name} frame count")
            case.frames.forEachIndexed { index, expected ->
                val actual = computed[index]
                assertClose(expected.x, actual.x, "${case.name} frame[$index].x")
                assertClose(expected.y, actual.y, "${case.name} frame[$index].y")
                assertClose(expected.width, actual.width, "${case.name} frame[$index].width")
                assertClose(expected.height, actual.height, "${case.name} frame[$index].height")
            }

            assertClose(case.contentWidth, layout.contentWidth(workspace), "${case.name} contentWidth")
        }
    }

    /**
     * The table has to keep covering the cases that make the arithmetic interesting, or it will go on
     * passing while testing less and less: a viewport small enough for the gap floor, one small
     * enough for the column-width floor, and a device held both ways.
     */
    @Test
    fun theGoldenTableStillCoversTheAwkwardViewports() {
        val cases = goldenCases().associateBy { it.name }

        val tiny = assertNotNull(cases["tiny"], "no `tiny` case")
        assertEquals(NiriLayout.MINIMUM_GAP, tiny.gap, "the gap floor is not exercised any more")
        assertTrue(
            tiny.widths.any { it == 280.0 },
            "the column-width floor is not exercised any more",
        )

        val portrait = assertNotNull(cases["phone-portrait"], "no `phone-portrait` case")
        val landscape = assertNotNull(cases["phone-landscape"], "no `phone-landscape` case")
        assertTrue(portrait.viewport.height > portrait.viewport.width)
        assertTrue(landscape.viewport.width > landscape.viewport.height)
    }
}
