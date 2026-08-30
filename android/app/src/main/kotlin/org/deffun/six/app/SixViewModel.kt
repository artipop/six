package org.deffun.six.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.deffun.six.core.AppStateSnapshot
import org.deffun.six.core.BrowserSnapshot
import org.deffun.six.core.NiriLayout
import org.deffun.six.core.Profile
import org.deffun.six.core.SearchEngine
import org.deffun.six.core.Size
import org.deffun.six.core.StripSnapshot
import org.deffun.six.core.TabSnapshot
import org.deffun.six.core.UserInput
import org.deffun.six.core.searchEngine

/** One window in the strip, as the UI needs it: what the column points at. */
data class TabState(
    val id: UUID,
    val profileId: UUID,
    val url: String? = null,
    val title: String = "",
)

/** Everything the strip draws from, in one value. */
data class SixState(
    val layout: NiriLayout = NiriLayout(),
    val tabs: Map<UUID, TabState> = emptyMap(),
    val profiles: List<Profile> = emptyList(),
    /** The window whose handle has become an address field, if any. Only ever one. */
    val editingTabId: UUID? = null,
    val searchEngine: SearchEngine = SearchEngine.DEFAULT,
    val isRestored: Boolean = false,
)

/**
 * The seam between the pure core and Compose.
 *
 * Everything below this class is a value: [NiriLayout] and its operations are pure functions, and
 * this holds the current one in a [StateFlow] and swaps it for the next. That is the whole of the
 * architecture — no observation, no mutation from the view, and the model stays testable on a JVM
 * because nothing here reaches back into it.
 */
class SixViewModel(application: Application) : AndroidViewModel(application) {

    private val environment = SixEnvironment(application)

    private val _state = MutableStateFlow(SixState())
    val state: StateFlow<SixState> = _state.asStateFlow()

    init {
        restore()
    }

    // MARK: Restoring and saving

    private fun restore() {
        viewModelScope.launch {
            val snapshot = withContext(Dispatchers.IO) { environment.snapshots.load() }
            val engine = withContext(Dispatchers.IO) {
                runCatching { environment.settings.searchEngine }.getOrDefault(SearchEngine.DEFAULT)
            }
            _state.update { current ->
                if (snapshot == null) {
                    // A first launch: one profile, one empty workspace, nothing open.
                    val profile = Profile(
                        id = UUID.randomUUID(),
                        name = "Personal",
                        colorHex = "#5B8DEF",
                        dataStoreId = UUID.randomUUID(),
                    )
                    // A first launch opens one window on the start page, the way the Mac does:
                    // an empty strip with nothing to tap is a browser that cannot be started.
                    val tabId = UUID.randomUUID()
                    current.copy(
                        layout = current.layout
                            .copy(activeProfileId = profile.id)
                            .insertColumn(tabId),
                        tabs = mapOf(tabId to TabState(tabId, profile.id)),
                        profiles = listOf(profile),
                        searchEngine = engine,
                        isRestored = true,
                    )
                } else {
                    val restored = current.layout
                        .copy(activeProfileId = snapshot.browser.selectedProfileId)
                        .restore(snapshot.browser.strips.associate { it.profileId to it.strip })
                    current.copy(
                        layout = restored,
                        tabs = snapshot.browser.tabs.associate {
                            it.id to TabState(it.id, it.profileId, it.url, it.title)
                        },
                        profiles = snapshot.browser.profiles,
                        searchEngine = engine,
                        isRestored = true,
                    )
                }
            }
        }
    }

    /**
     * The snapshot is rewritten whole, and the branches this platform does not model are carried
     * across from the file it was read from — never rebuilt, because rebuilding is how they get lost.
     */
    fun save() {
        val current = _state.value
        if (!current.isRestored) return
        viewModelScope.launch(Dispatchers.IO) {
            val previous = runCatching { environment.snapshots.load() }.getOrNull()
            environment.snapshots.save(
                AppStateSnapshot(
                    browser = BrowserSnapshot(
                        profiles = current.profiles,
                        selectedProfileId = current.layout.activeProfileId,
                        tabs = current.tabs.values.map {
                            TabSnapshot(it.id, it.profileId, it.url, it.title)
                        },
                        strips = current.layout.strips.map { (id, strip) -> StripSnapshot(id, strip) },
                        research = previous?.browser?.research,
                    ),
                    agent = previous?.agent,
                    window = previous?.window,
                ),
            )
        }
    }

    // MARK: The strip

    /**
     * The viewport, in **dp** rather than pixels.
     *
     * `NiriLayout`'s floors are 10, 280 and 200 — the Mac's points, which are dp here. Handing it
     * pixels would make the gap a hairline on a 3× screen and the minimum column a third of the one
     * intended, and it would do it silently, because every one of those numbers is still a valid
     * length. The conversion belongs at this boundary and nowhere else.
     */
    fun onViewportChanged(stripSpaceDp: Size) {
        _state.update { it.copy(layout = it.layout.updateViewport(stripSpaceDp)) }
    }

    fun focus(tabId: UUID) {
        _state.update { it.copy(layout = it.layout.focus(tabId)) }
        save()
    }

    fun focusColumn(delta: Int) {
        _state.update { it.copy(layout = it.layout.focusColumn(delta)) }
        save()
    }

    fun focusWorkspace(delta: Int) {
        _state.update { it.copy(layout = it.layout.focusWorkspace(delta)) }
        save()
    }

    /** Opens a column on the start page, focused, to the right of the focused one. */
    fun openColumn(url: String? = null): UUID {
        val id = UUID.randomUUID()
        _state.update { current ->
            current.copy(
                layout = current.layout.insertColumn(id),
                tabs = current.tabs + (id to TabState(id, current.layout.activeProfileId, url)),
            )
        }
        save()
        return id
    }

    fun closeColumn(tabId: UUID) {
        _state.update { it.copy(layout = it.layout.removeColumn(tabId), tabs = it.tabs - tabId) }
        save()
    }

    /**
     * The rubber band, in strip space, while a drag is still below the switch threshold.
     *
     * The arguments are the drag's total so far, not its latest increment: Compose reports deltas
     * and the band is an absolute displacement, and adding one to the other every frame is how a
     * strip ends up moving several times as far as the finger did.
     */
    fun previewDrag(along: Double, across: Double) {
        _state.update {
            it.copy(layout = it.layout.copy(horizontalPreview = along, verticalPreview = across))
        }
    }

    /**
     * Letting go either commits a step or springs back; nothing rests half-way.
     *
     * Across the strip wins over along when a drag was both, because the workspaces are the coarser
     * move and a diagonal that changes both at once is never what was meant. The threshold is a
     * fraction of the viewport rather than a distance in dp, for the same reason the gaps are.
     */
    fun commitDrag() {
        val layout = _state.value.layout
        val alongThreshold = layout.viewport.width * DRAG_COMMIT_FRACTION
        val acrossThreshold = layout.viewport.height * DRAG_COMMIT_FRACTION

        when {
            layout.verticalPreview > acrossThreshold -> focusWorkspace(-1)
            layout.verticalPreview < -acrossThreshold -> focusWorkspace(1)
            // Dragging along-positive pulls the strip back towards its start, so it reveals the
            // column before this one.
            layout.horizontalPreview > alongThreshold -> focusColumn(-1)
            layout.horizontalPreview < -alongThreshold -> focusColumn(1)
        }
        endDrag()
    }

    fun endDrag() {
        _state.update { it.copy(layout = it.layout.copy(horizontalPreview = 0.0, verticalPreview = 0.0)) }
    }

    // MARK: The address field

    /**
     * A tap on the window that already has focus turns its title into the field; a tap on any other
     * only focuses it, so walking the strip never opens the keyboard.
     */
    fun handleTapped(tabId: UUID) {
        if (_state.value.layout.focusedTabId == tabId) {
            _state.update { it.copy(editingTabId = tabId) }
        } else {
            focus(tabId)
        }
    }

    fun cancelEditing() {
        _state.update { it.copy(editingTabId = null) }
    }

    /**
     * What was typed, turned into something to load by the rule both platforms share — a recognised
     * scheme is an address, a bare host gets `https://`, anything else is a search.
     */
    fun submitAddress(tabId: UUID, text: String) {
        val url = UserInput.url(text, _state.value.searchEngine)
        _state.update { it.copy(editingTabId = null) }
        if (url == null) return
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            current.copy(tabs = current.tabs + (tabId to tab.copy(url = url, title = "")))
        }
        save()
    }

    // MARK: What the page reports

    /** A committed navigation: the tab's address, and a row in the history the Mac also reads. */
    fun onPageStarted(tabId: UUID, url: String) {
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            current.copy(tabs = current.tabs + (tabId to tab.copy(url = url)))
        }
        val tab = _state.value.tabs[tabId] ?: return
        viewModelScope.launch(Dispatchers.IO) {
            environment.history.record(url, tab.title, tab.profileId)
        }
        save()
    }

    /** Titles arrive after the navigation commits, on both platforms. */
    fun onTitleChanged(tabId: UUID, title: String) {
        if (title.isEmpty()) return
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            current.copy(tabs = current.tabs + (tabId to tab.copy(title = title)))
        }
        val tab = _state.value.tabs[tabId] ?: return
        val url = tab.url ?: return
        viewModelScope.launch(Dispatchers.IO) {
            environment.history.updateTitle(title, url, tab.profileId)
        }
        save()
    }

    private companion object {
        /** How far a drag has to travel before letting go steps rather than springs back. */
        const val DRAG_COMMIT_FRACTION = 0.15
    }

    override fun onCleared() {
        environment.close()
        super.onCleared()
    }
}
