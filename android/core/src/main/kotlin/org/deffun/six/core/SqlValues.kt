package org.deffun.six.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.temporal.ChronoField
import java.util.UUID

/**
 * How a `UUID` and a `Date` look **in the database**, which is not how they look in `state.json`.
 *
 * The same two types are written two different ways by the same app, and neither difference fails
 * loudly:
 *
 * | | `state.json` | `six.sqlite` |
 * |---|---|---|
 * | `UUID` | `"ED2FCED9-…"` uppercase | `ed2fced9-…` **lowercase** |
 * | `Date` | `776000000.5` seconds since 2001 | `"2026-08-29 05:39:33.127"` UTC text |
 *
 * The UUID one is the dangerous half. SQLite compares text with BINARY collation unless told
 * otherwise, and none of these columns is told otherwise — so a `profileID` written uppercase does
 * not match the Mac's rows and does not error either. The profile simply has no history, on a
 * database visibly full of it.
 */

/**
 * Text UUIDs in this schema are lowercase, the way SQLiteData writes them.
 *
 * `UUID.toString()` is already lowercase in Java, so this call changes nothing today and is here to
 * be the one place the convention is stated — the mirror of [UuidSerializer], which uppercases for
 * JSON. The uppercase form reaches SQL only by hand, from someone reaching for the convention the
 * snapshot uses; going through this function is what makes that not happen.
 */
fun UUID.toSqlText(): String = toString().lowercase()

/** Lenient on the way in: a row written by any of these conventions still reads. */
fun uuidFromSqlText(text: String): UUID = UUID.fromString(text)

/**
 * GRDB's default `Date` storage: `yyyy-MM-dd HH:mm:ss.SSS`, in UTC, with no zone marker at all.
 *
 * Because it carries no offset, reading it as local time silently shifts every timestamp by the
 * machine's offset — history in the wrong order, "today" starting at the wrong hour. The formatter
 * is pinned to UTC for that reason and not for tidiness.
 */
object GrdbDate {

    private val WRITER: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss.SSS").withZone(ZoneOffset.UTC)

    /**
     * Reading accepts what writing does not produce: GRDB itself will store a whole second as
     * `…:33` and a date alone as `2026-08-29`, and a file that has been through more than one
     * version of anything is worth reading leniently.
     */
    private val READER: DateTimeFormatter = DateTimeFormatterBuilder()
        .appendPattern("yyyy-MM-dd")
        .optionalStart().appendLiteral(' ').optionalEnd()
        .optionalStart().appendLiteral('T').optionalEnd()
        .optionalStart().appendPattern("HH:mm")
        .optionalStart().appendLiteral(':').appendPattern("ss").optionalEnd()
        .optionalStart().appendFraction(ChronoField.NANO_OF_SECOND, 0, 9, true).optionalEnd()
        .optionalEnd()
        .optionalStart().appendLiteral('Z').optionalEnd()
        .parseDefaulting(ChronoField.HOUR_OF_DAY, 0)
        .parseDefaulting(ChronoField.MINUTE_OF_HOUR, 0)
        .parseDefaulting(ChronoField.SECOND_OF_MINUTE, 0)
        .toFormatter()
        .withZone(ZoneOffset.UTC)

    fun format(instant: Instant): String = WRITER.format(instant)

    fun parse(text: String): Instant = Instant.from(READER.parse(text.trim()))
}
