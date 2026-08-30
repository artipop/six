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
import org.deffun.six.core.releaseDrag
import org.deffun.six.core.SearchEngine
import org.deffun.six.core.Size
import org.deffun.six.core.StripSnapshot
import org.deffun.six.core.TabSnapshot
import org.deffun.six.core.UserInput
import org.deffun.six.core.Visit
import org.deffun.six.core.searchEngine

/** One window in the strip, as the UI needs it: what the column points at. */
data class TabState(
    val id: UUID,
    val profileId: UUID,
    val url: String? = null,
    val title: String = "",
    /**
     * Whether the page has anywhere to go. A `WebView` does not publish this, so it is read from the
     * view whenever it says its history changed — the toolbar has to know without asking every frame.
     */
    val canGoBack: Boolean = false,
    val canGoForward: Boolean = false,
    val isLoading: Boolean = false,
)

/** Everything the strip draws from, in one value. */
data class SixState(
    val layout: NiriLayout = NiriLayout(),
    val tabs: Map<UUID, TabState> = emptyMap(),
    val profiles: List<Profile> = emptyList(),
    /** The window whose handle has become an address field, if any. Only ever one. */
    val editingTabId: UUID? = null,
    val searchEngine: SearchEngine = SearchEngine.DEFAULT,
    /** True while the system is asking for memory back: only the focused column keeps its page. */
    val isUnderMemoryPressure: Boolean = false,
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

    fun focusWorkspaceAt(index: Int) {
        _state.update { it.copy(layout = it.layout.focusWorkspaceAt(index)) }
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
        LivePages.forget(tabId)
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

    /** Letting go either commits a step or springs back — the rule itself lives in `:core`. */
    fun commitDrag() {
        _state.update { it.copy(layout = it.layout.releaseDrag()) }
        save()
    }

    fun endDrag() {
        _state.update { it.copy(layout = it.layout.copy(horizontalPreview = 0.0, verticalPreview = 0.0)) }
    }

    /** The profile on screen, newest first. Reading the database is not the main thread's work. */
    suspend fun historyEntries(): List<Visit> = withContext(Dispatchers.IO) {
        runCatching {
            environment.history.entries(_state.value.layout.activeProfileId, limit = 500)
        }.getOrDefault(emptyList())
    }

    /**
     * "Clear history?" for the profile on screen — not for every profile, which is the whole point
     * of profiles. The Mac asks the same question with the same two answers.
     *
     * Site data is the profile's cookies and local storage: clearing it signs you out everywhere in
     * that profile. Bookmarks are a different table and are not touched by either answer.
     */
    fun clearHistory(includingSiteData: Boolean) {
        val current = _state.value
        val profileId = current.layout.activeProfileId
        val storeName = current.profiles.firstOrNull { it.id == profileId }
            ?.let { WebProfiles.storeName(it) }

        viewModelScope.launch(Dispatchers.IO) {
            runCatching { environment.history.clear(profileId) }
            if (includingSiteData) WebProfiles.clearSiteData(storeName)
        }
    }

    fun goBack() {
        LivePages.goBack(_state.value.layout.focusedTabId)
    }

    fun goForward() {
        LivePages.goForward(_state.value.layout.focusedTabId)
    }

    /** The overview: on a phone this only rescales the strip — there is no grid behind it yet. */
    fun toggleOverview() {
        _state.update { it.copy(layout = it.layout.setOverview(!it.layout.isOverview)) }
        save()
    }

    /**
     * The system asking for memory back.
     *
     * The Mac watches a pressure band and shrinks its live-page budget; this is the same move with
     * Android's vocabulary. It narrows the live set rather than touching any `WebView` directly —
     * the composition is what releases a page here, and each one saves its own state on the way out.
     */
    fun onMemoryPressure(isUnderPressure: Boolean) {
        _state.update { it.copy(isUnderMemoryPressure = isUnderPressure) }
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
        // Whatever was kept of this column's page is about to be wrong: restoring it would navigate
        // quietly back to where the column used to be, which reads as the address bar not working.
        LivePages.forget(tabId)
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
            current.copy(tabs = current.tabs + (tabId to tab.copy(url = url, isLoading = true)))
        }
        val tab = _state.value.tabs[tabId] ?: return
        viewModelScope.launch(Dispatchers.IO) {
            environment.history.record(url, tab.title, tab.profileId)
        }
        save()
    }

    fun onPageFinished(tabId: UUID) {
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            current.copy(tabs = current.tabs + (tabId to tab.copy(isLoading = false)))
        }
    }

    /** The page's history moved. Only the two flags the toolbar draws from. */
    fun onHistoryChanged(tabId: UUID, canGoBack: Boolean, canGoForward: Boolean) {
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            if (tab.canGoBack == canGoBack && tab.canGoForward == canGoForward) return@update current
            current.copy(
                tabs = current.tabs + (tabId to tab.copy(canGoBack = canGoBack, canGoForward = canGoForward)),
            )
        }
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

    override fun onCleared() {
        environment.close()
        super.onCleared()
    }
}
