package org.deffun.six.core

import java.net.URI
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** One device a site can ask for. */
@Serializable
enum class SitePermission(val id: String) {
    @SerialName("camera")
    CAMERA("camera"),

    @SerialName("microphone")
    MICROPHONE("microphone"),

    /**
     * `DeviceOrientationEvent` and `DeviceMotionEvent`. A desktop has neither sensor and the Mac
     * still answers the question; a phone has both, so here it is the one of the three that is
     * actually about this device.
     */
    @SerialName("motion")
    MOTION("motion"),
}

/** One remembered answer. */
@Serializable
data class PermissionDecision(
    @Serializable(with = UuidSerializer::class)
    @SerialName("profileID")
    val profileId: UUID,
    val origin: String,
    val permission: SitePermission,
    val isAllowed: Boolean,
)

/** One site in one profile — a row of the panel. */
data class PermissionSite(val profileId: UUID, val origin: String)

/**
 * What the user answered when a site asked for the camera, the microphone or the motion sensors —
 * and, while a question is on screen, the question itself.
 *
 * A port of the Mac's `SitePermissions`, which is already in `SixCore` for exactly this reason: the
 * memory, the queue and the rules are the same everywhere, and only the type a request arrives as
 * differs. On Apple that is `WKSecurityOrigin`; here it is `PermissionRequest`. By the time either
 * reaches [decide] it has said only what was asked for and by which origin, and an answer depends on
 * nothing else.
 *
 * An answer is filed under the **origin** (`https://example.com`, port and all), not the host: the
 * same host over plain HTTP is a different site, and the origin is the boundary the web platform
 * itself draws.
 *
 * A private profile's answers live in memory for as long as the profile does and are never written
 * down — the point of the profile is that nothing about it survives it.
 *
 * ## Not the only gate
 *
 * Android holds the camera and the microphone behind a runtime permission of its own, and that one
 * comes first: the page's request cannot be granted before the *app* has been allowed the device. So
 * the first time a user ever grants a site costs two answers, one for the app and one for the site,
 * and every request after it costs at most one. The Mac says the same thing about TCC.
 */
class SitePermissions(
    initial: List<PermissionDecision> = emptyList(),
    /**
     * Where an answer goes when it is written down, or null to keep everything in memory.
     *
     * The Mac hands this class a `SettingsStore` directly. Here it is a callback, and for a reason
     * that is Android's rather than a preference: the settings table is behind a database that must
     * not be opened on the main thread, while a page's question arrives on it. So the decisions are
     * read once, on the way in, and every write is posted back out to whoever owns the file.
     */
    private val onSave: ((List<PermissionDecision>) -> Unit)? = null,
) {

    /** A question waiting for the user, drawn as a bar in the window that asked. */
    class Question internal constructor(
        val profileId: UUID,
        /** `https://example.com` — what the answer is filed under. */
        val origin: String,
        /** Everything asked for at once: "camera and microphone" is one bar and two answers. */
        val permissions: List<SitePermission>,
        internal val pending: Pending,
    ) {
        val id: UUID = UUID.randomUUID()

        /** What the bar shows. The origin without its scheme, which is what people call a site. */
        val host: String get() = runCatching { URI(origin).host }.getOrNull() ?: origin
    }

    /**
     * How the answer gets back to the page. Emptied on the first answer: a window can be closed
     * while its bar is still up, and a request granted twice is a crash on some platforms and a lie
     * on the rest.
     */
    internal class Pending(private var answer: ((Boolean) -> Unit)?) {
        fun resume(allowed: Boolean) {
            val callback = answer
            answer = null
            callback?.invoke(allowed)
        }
    }

    var decisions: List<PermissionDecision> = initial
        private set

    private val queues = mutableMapOf<UUID, MutableList<Question>>()

    /** Whether a profile's answers may be written down. */
    var isPrivate: (UUID) -> Boolean = { false }

    /**
     * Told when a question is asked or answered.
     *
     * SwiftUI watches the Mac's object for free; Compose watches a `StateFlow`, and a question
     * arriving from a `WebChromeClient` callback assigns nothing. So the one thing the Mac gets for
     * nothing is said out loud here, exactly as the GTK front needed it said.
     */
    var onQuestionsChanged: (() -> Unit)? = null

    /**
     * The answers already on file, once whoever owns the database has managed to read them.
     *
     * Separate from the constructor because that read is disk work and the object has to exist
     * before it: a question can arrive in the moment between launching and finishing that read, and
     * one that is answered from an empty memory merely asks again rather than getting it wrong.
     */
    fun restore(saved: List<PermissionDecision>) {
        decisions = saved
    }

    // MARK: Answering the page

    /**
     * The page is asking. Answers from memory when this site has been answered before, and otherwise
     * puts the question on the window and calls back when it has been answered.
     */
    fun decide(
        asked: List<SitePermission>,
        origin: String,
        windowId: UUID,
        profileId: UUID,
        answer: (Boolean) -> Unit,
    ) {
        // Nothing to file an answer under (an opaque origin, a `data:` page): the safe answer is no.
        if (asked.isEmpty() || origin.isEmpty()) return answer(false)

        val known = asked.mapNotNull { decision(it, origin, profileId) }
        if (known.size == asked.size) {
            // One "no" among them is a no: a page that asked for the camera *and* the microphone was
            // asking for a call, and half a call is not what either answer meant.
            return answer(known.all { it })
        }

        val question = Question(profileId, origin, asked, Pending(answer))
        queues.getOrPut(windowId) { mutableListOf() }.add(question)
        onQuestionsChanged?.invoke()
    }

    /** The question this window is showing, if any. */
    fun question(windowId: UUID): Question? = queues[windowId]?.firstOrNull()

    /** The bar's two buttons. Remembers the answer and lets the page go. */
    fun answer(allowed: Boolean, windowId: UUID) {
        val queue = queues[windowId] ?: return
        if (queue.isEmpty()) return
        val question = queue.removeAt(0)
        if (queue.isEmpty()) queues.remove(windowId)
        for (permission in question.permissions) {
            set(allowed, permission, question.origin, question.profileId)
        }
        question.pending.resume(allowed)
        onQuestionsChanged?.invoke()
    }

    /**
     * The window is closing, or its page is being given back: a question nobody can answer any more
     * is answered no. Denying rather than dropping it is deliberate — the page is waiting on this
     * call, and a promise that never lands is a page that never finds out.
     */
    fun forgetWindow(windowId: UUID) {
        val queue = queues.remove(windowId) ?: return
        for (question in queue) question.pending.resume(false)
        onQuestionsChanged?.invoke()
    }

    // MARK: What has been decided

    fun decision(permission: SitePermission, origin: String, profileId: UUID): Boolean? =
        decisions.firstOrNull {
            it.profileId == profileId && it.origin == origin && it.permission == permission
        }?.isAllowed

    /** Everything decided about one site. */
    fun decisions(origin: String, profileId: UUID): Map<SitePermission, Boolean> =
        decisions
            .filter { it.profileId == profileId && it.origin == origin }
            .associate { it.permission to it.isAllowed }

    /** Every site with a remembered answer, in the order they were first answered. */
    val sites: List<PermissionSite>
        get() {
            val seen = LinkedHashSet<PermissionSite>()
            for (decision in decisions) seen.add(PermissionSite(decision.profileId, decision.origin))
            return seen.toList()
        }

    /** Writes one answer down. Used by the bar, and by the panel when someone changes their mind. */
    fun set(allowed: Boolean, permission: SitePermission, origin: String, profileId: UUID) {
        val index = decisions.indexOfFirst {
            it.profileId == profileId && it.origin == origin && it.permission == permission
        }
        decisions = if (index >= 0) {
            decisions.toMutableList().also { it[index] = it[index].copy(isAllowed = allowed) }
        } else {
            decisions + PermissionDecision(profileId, origin, permission, allowed)
        }
        save()
    }

    /** Take it back: the site asks again the next time it needs the device. */
    fun forget(origin: String, profileId: UUID) {
        decisions = decisions.filterNot { it.profileId == profileId && it.origin == origin }
        save()
    }

    fun forgetAll() {
        decisions = emptyList()
        save()
    }

    /** A profile is gone; so are the answers given inside it. */
    fun forgetProfile(profileId: UUID) {
        decisions = decisions.filterNot { it.profileId == profileId }
        save()
    }

    private fun save() {
        onSave?.invoke(decisions.filterNot { isPrivate(it.profileId) })
    }

    companion object {
        /**
         * The origin an answer is filed under, built from an address.
         *
         * The default port is left off, because `https://example.com` and `https://example.com:443`
         * are the same origin and filing them apart would ask twice. A page with no host — a
         * `file:` page — is filed under its scheme alone, which is what that origin *is* and beats
         * denying a local page with no question asked.
         */
        fun originOf(url: String?): String? {
            if (url.isNullOrEmpty()) return null
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase()
            if (scheme.isNullOrEmpty()) return null
            val host = uri.host?.lowercase()
            if (host.isNullOrEmpty()) return "$scheme://"
            val base = "$scheme://$host"
            val standard = when (scheme) {
                "https" -> 443
                "http" -> 80
                else -> null
            }
            val port = uri.port
            return if (port == -1 || port == standard) base else "$base:$port"
        }
    }
}

/**
 * The setting lives in the `settings` table as one JSON document under `permissions.sites`; what its
 * shape means lives here, beside the type it means it as.
 *
 * The UUIDs inside it are **uppercase**, unlike every UUID in a column of that same database: this
 * is a `JSONEncoder` document that happens to be stored in SQLite, so it follows the snapshot's
 * convention and not the schema's. Getting that backwards would silently give a profile a second,
 * empty set of answers.
 */
var SettingsStore.sitePermissions: List<PermissionDecision>
    get() = this[SettingsKeys.SITE_PERMISSIONS]
        ?.let { json ->
            runCatching {
                SnapshotJson.decodeFromString(ListSerializer(PermissionDecision.serializer()), json)
            }.getOrNull()
        }
        ?: emptyList()
    set(value) {
        // An absent setting and an empty one mean the same thing, so the row goes rather than
        // holding an empty list — `keepingEmpty: false` on the Mac.
        if (value.isEmpty()) {
            remove(SettingsKeys.SITE_PERMISSIONS)
        } else {
            this[SettingsKeys.SITE_PERMISSIONS] =
                SnapshotJson.encodeToString(ListSerializer(PermissionDecision.serializer()), value)
        }
    }
