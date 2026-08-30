package org.deffun.six.core

import java.time.Instant
import java.util.UUID
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * The three places Swift's `Codable` and kotlinx.serialization disagree about what a value looks
 * like in JSON.
 *
 * None of them is a matter of taste. `state.json` is written by one front end and read by another,
 * so where `JSONEncoder` has a default, that default is the format — and each of these is a default
 * quiet enough to be discovered in production rather than in a compiler error.
 */

/**
 * `UUID` through `Codable` is an **uppercase** string; `UUID.toString()` in Java is lowercase.
 *
 * Reading is case-insensitive either way, so this is only ever caught on a round trip — and then not
 * by a crash but by the Mac treating a tab it already has as one it has never seen.
 */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("java.util.UUID", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: UUID) =
        encoder.encodeString(value.toString().uppercase())

    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
}

/**
 * `Date` through `Codable`, with `JSONEncoder`'s default `.deferredToDate` strategy, is a bare
 * `Double`: seconds since Apple's reference date, **2001-01-01 UTC** — not the Unix epoch.
 *
 * `SnapshotStore` sets no `dateEncodingStrategy`, so this is the format. Reading these as Unix
 * seconds lands every timestamp in 1970 and every "modified" date 31 years early, which sorts wrong
 * and expires nothing — a bug that looks like data rather than like a parser.
 */
object AppleDateSerializer : KSerializer<Instant> {
    /** 2001-01-01T00:00:00Z in Unix seconds. */
    const val REFERENCE_EPOCH_SECONDS = 978_307_200L

    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Foundation.Date", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Instant) {
        val seconds = (value.epochSecond - REFERENCE_EPOCH_SECONDS).toDouble()
        encoder.encodeDouble(seconds + value.nano / 1_000_000_000.0)
    }

    override fun deserialize(decoder: Decoder): Instant {
        val interval = decoder.decodeDouble()
        val whole = Math.floor(interval)
        val nanos = ((interval - whole) * 1_000_000_000.0).toLong()
        return Instant.ofEpochSecond(whole.toLong() + REFERENCE_EPOCH_SECONDS, nanos)
    }
}

/**
 * `URL` through `Codable` is a plain string, and an invalid one throws on decode.
 *
 * six keeps URLs as strings on this side rather than as `java.net.URI`: the value is round-tripped
 * far more often than it is inspected, and a URL the Mac accepted and Java rejects would cost the
 * whole snapshot rather than one tab. The one place it must be parsed — loading a page — parses it
 * there, where failing is a page that does not load instead of a session that does not restore.
 */
typealias UrlString = String
