package org.deffun.six.core

import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/**
 * What six restores on the next launch — the same file the Mac writes, read and written here.
 *
 * ## What Android models, and what it only carries
 *
 * `platforms.md` gives the rule the phone already follows: a front end that does not have a
 * subsystem still has to hand that subsystem's state back unharmed, because the next launch may be
 * on the machine that does. iOS keeps `ResearchRun` for exactly this reason while excluding the
 * coordinator that drives it.
 *
 * Android takes that further, because it is further away. Three branches are held as raw
 * [JsonElement] and written back byte for byte:
 *
 * - [BrowserSnapshot.research] — deep research is an agent driving the browser, and there are no
 *   agents here.
 * - [AppStateSnapshot.agent] — the ACP sessions and their transcripts, likewise.
 * - [AppStateSnapshot.window] — an `NSWindow` frame and its fullscreen flag. A phone has one window
 *   and it is the screen.
 *
 * Modelling them would buy nothing and cost the thing that matters: every field added on the Mac
 * would be a field silently dropped by the phone until someone noticed.
 */
@Serializable
data class AppStateSnapshot(
    val version: Int = CURRENT_VERSION,
    val browser: BrowserSnapshot,
    /** Opaque: the agent layer is not on this platform. Carried, never interpreted. */
    val agent: JsonElement? = null,
    /** Opaque: the Mac's window frame and fullscreen flag. Absent in files from before it was kept. */
    val window: JsonElement? = null,
) {
    companion object {
        const val CURRENT_VERSION = 1
    }
}

/** Profiles, the windows in them and where each sits in its profile's strip. */
@Serializable
data class BrowserSnapshot(
    val profiles: List<Profile>,
    @Serializable(with = UuidSerializer::class)
    @SerialName("selectedProfileID")
    val selectedProfileId: UUID,
    val tabs: List<TabSnapshot>,
    val strips: List<StripSnapshot>,
    /** Opaque: deep-research runs. Absent in files from before them. */
    val research: JsonElement? = null,
)

/**
 * One profile: its own website data store, its own strip of workspaces, its own bookmarks folder.
 *
 * `dataStoreID` names a `WKWebsiteDataStore` on the Mac and an `androidx.webkit.Profile` here — two
 * different things holding the same cookies, which is the whole reason the id is stored rather than
 * derived. It is preserved exactly even though nothing on Android can hand it to WebKit.
 */
@Serializable
data class Profile(
    @Serializable(with = UuidSerializer::class)
    val id: UUID,
    val name: String,
    /** `#RRGGBB`. The UI parses it; the file keeps it as written. */
    val colorHex: String,
    @Serializable(with = UuidSerializer::class)
    @SerialName("dataStoreID")
    val dataStoreId: UUID,
    val isPrivate: Boolean = false,
)

@Serializable
data class TabSnapshot(
    @Serializable(with = UuidSerializer::class)
    val id: UUID,
    @Serializable(with = UuidSerializer::class)
    @SerialName("profileID")
    val profileId: UUID,
    /** Absent is the start page — not an empty string, which would be a page that fails to load. */
    val url: UrlString? = null,
    val title: String = "",
    /** A document window: the id of its Markdown file under `Documents/`; the text lives there. */
    val document: DocumentSnapshot? = null,
)

/** What the snapshot keeps of a document — everything but the text. */
@Serializable
data class DocumentSnapshot(
    @Serializable(with = UuidSerializer::class)
    val id: UUID,
    val title: String,
    @Serializable(with = AppleDateSerializer::class)
    val modifiedAt: java.time.Instant,
    val fileURL: UrlString? = null,
    val showsPreview: Boolean = false,
)

/** One profile's workspace stack; [NiriStrip] itself is the stored shape. */
@Serializable
data class StripSnapshot(
    @Serializable(with = UuidSerializer::class)
    @SerialName("profileID")
    val profileId: UUID,
    val strip: NiriStrip,
)
