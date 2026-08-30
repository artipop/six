package org.deffun.six.core

import java.io.File
import java.io.IOException
import kotlinx.serialization.json.Json

/**
 * The JSON six's snapshot is written in.
 *
 * Two settings are parity with `JSONEncoder`, not preference:
 *
 * - [Json.explicitNulls] off, because Swift's synthesised `encode(to:)` uses `encodeIfPresent` for
 *   optionals, so a nil is an **absent key** rather than a `null`. A file full of explicit nulls
 *   still decodes on the Mac, but it stops being the same file, and "the same file" is the contract.
 * - [Json.encodeDefaults] on, and this one is not cosmetic. Kotlin omits a property equal to its
 *   default; Swift's synthesised `encode(to:)` writes every non-optional property whether or not it
 *   matches one. And the synthesised `init(from:)` on the other side does **not** fall back to a
 *   default when a key is missing — it throws `keyNotFound`. So a snapshot written with Kotlin's
 *   default settings drops `widthIndex`, `focus`, `name`, `columns` and `isPrivate`, and the Mac
 *   then fails to decode the file at all: not a column with the wrong width, the whole session gone.
 *   Found by reading a file the Mac had actually written, which no amount of round-tripping our own
 *   output would have caught.
 * - [Json.ignoreUnknownKeys] on, because `JSONDecoder` ignores them too. This is not forward
 *   compatibility — a key neither side models is dropped on the next write by both — it is
 *   agreement about *when* that happens. [AppStateSnapshot.version] is the real guard, and the
 *   branches Android holds as raw JSON are how the fields that matter survive anyway.
 *
 * What is left differing is cosmetic and symmetric: key *order*, and an integral double written
 * `-720.0` here and `-720` there. Both sides parse either.
 *
 * `prettyPrint` is the Mac's too. Key *order* is not: `JSONEncoder` sorts keys and
 * kotlinx.serialization writes them in declaration order. Nothing diffs these files across
 * platforms, so semantic equality is the bar; making the declaration order alphabetical to chase
 * byte-identity would trade a real property (fields grouped by meaning) for a decorative one.
 */
val SnapshotJson: Json = Json {
    prettyPrint = true
    prettyPrintIndent = "  "
    encodeDefaults = true
    explicitNulls = false
    ignoreUnknownKeys = true
}

/** Where a snapshot lives. One file today; the interface is the seam for anything else. */
interface SnapshotStore {
    /** Null when there is no file, or when it was written by a version this build cannot read. */
    fun load(): AppStateSnapshot?

    fun save(snapshot: AppStateSnapshot)
}

/**
 * One pretty-printed JSON file, written atomically. Readable and diffable, which is worth more than
 * speed for a few hundred windows.
 */
class FileSnapshotStore(private val file: File) : SnapshotStore {

    override fun load(): AppStateSnapshot? {
        if (!file.exists()) return null
        val snapshot = SnapshotJson.decodeFromString(
            AppStateSnapshot.serializer(),
            file.readText(),
        )
        // An older build refuses a newer file instead of guessing at it.
        if (snapshot.version > AppStateSnapshot.CURRENT_VERSION) return null
        return snapshot
    }

    override fun save(snapshot: AppStateSnapshot) {
        file.parentFile?.mkdirs()
        // Atomic in the sense that matters: a crash mid-write leaves the previous snapshot intact
        // rather than a half-written one. `File.renameTo` is the atomic step, and it is only atomic
        // within a filesystem — hence a temporary beside the target rather than in the cache dir.
        val temporary = File(file.parentFile, "${file.name}.new")
        temporary.writeText(SnapshotJson.encodeToString(AppStateSnapshot.serializer(), snapshot))
        if (!temporary.renameTo(file)) {
            // Some filesystems refuse a rename onto an existing file.
            if (!(file.delete() && temporary.renameTo(file))) {
                temporary.delete()
                throw IOException("could not replace ${file.path}")
            }
        }
    }
}
