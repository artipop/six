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
import org.deffun.six.core.Bookmark
import org.deffun.six.core.BookmarkScope
import org.deffun.six.core.buildBrowserSnapshot
import org.deffun.six.core.NiriLayout
import org.deffun.six.core.PageDialogAnswer
import org.deffun.six.core.PageDialogQueue
import org.deffun.six.core.PageDialogRequest
import org.deffun.six.core.Profile
import org.deffun.six.core.ReadablePage
import org.deffun.six.core.releaseDrag
import org.deffun.six.core.SearchEngine
import org.deffun.six.core.PermissionSite
import org.deffun.six.core.SitePermission
import org.deffun.six.core.SitePermissions
import org.deffun.six.core.sitePermissions
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

/** A site's question, flattened for the view. */
data class PermissionQuestion(
    val tabId: UUID,
    val host: String,
    val permissions: List<SitePermission>,
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
    /** The question a site is waiting on, drawn as a bar in the window that asked. */
    val permissionQuestion: PermissionQuestion? = null,
    /** App-level permissions the system still has to be asked for, once the site has been allowed. */
    val pendingSystemPermissions: Set<String> = emptySet(),
    /** Bumped whenever an answer is written or taken back, so an open panel re-reads. */
    val permissionRevision: Int = 0,
    /** The dialog a page is waiting on, if any. One at a time, for the whole window. */
    val pageDialog: PageDialogRequest? = null,
    /** Bumped when a bookmark is saved or removed, so an open panel re-reads. */
    val bookmarkRevision: Int = 0,
    /** What the last save said, if it said anything: a page with no text is not an error to log. */
    val bookmarkNotice: String? = null,
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

    private val environment = SixEnvironment(application).apply {
        // A bookmark's file goes in its profile's folder, and only the state knows the names.
        profileNameFor = { id -> _state.value.profiles.firstOrNull { it.id == id }?.name }
    }

    init {
        // Drawing is quick and on the main thread because the view is; writing the file is not.
        LivePages.onCapture = { tabId, webView ->
            // Drawn where the view is, encoded and filed where nothing is waiting.
            environment.thumbnails.capture(webView)?.let { bitmap ->
                viewModelScope.launch(Dispatchers.IO) { environment.thumbnails.write(tabId, bitmap) }
            }
        }
    }

    /**
     * The Mac's own permission model, unchanged. It calls back when a question appears or is
     * answered, because a `WebChromeClient` callback assigns nothing a `StateFlow` would notice.
     */
    private val sitePermissions = SitePermissions(
        onSave = { decisions ->
            // The write goes to the settings table, which is behind a database this must not open
            // from wherever a page's question happened to arrive.
            viewModelScope.launch(Dispatchers.IO) {
                runCatching { environment.settings.sitePermissions = decisions }
            }
        },
    ).apply {
        onQuestionsChanged = { publishQuestion() }
        isPrivate = { profileId -> this@SixViewModel.isPrivate(profileId) }
    }

    private fun isPrivate(profileId: UUID): Boolean =
        _state.value.profiles.firstOrNull { it.id == profileId }?.isPrivate == true

    /** The page waiting on an answer that has already been given, pending the system's own. */
    private var pendingGrant: ((Boolean) -> Unit)? = null

    /** Which window's bar is showing. One at a time, like the Mac's. */
    private var questionWindowId: UUID? = null

    /**
     * `alert()`, `confirm()`, `prompt()` and `<input type="file">`.
     *
     * One queue for the whole window rather than one per column, because a phone has one window: a
     * second page asking waits for the first to be answered.
     */
    private val pageDialogs = PageDialogQueue().apply {
        onChanged = { _state.update { it.copy(pageDialog = current) } }
    }

    private val _state = MutableStateFlow(SixState())
    val state: StateFlow<SixState> = _state.asStateFlow()

    init {
        restore()
    }

    // MARK: Restoring and saving

    private fun restore() {
        viewModelScope.launch {
            // A private profile is never in the file, so after a kill nothing left knows its store
            // existed — except the engine, which still has it. Swept before anything else opens one.
            launch(Dispatchers.IO) {
                runCatching { WebProfiles.deleteOrphanedPrivateStores(profilesOnFile()) }
            }
            val snapshot = withContext(Dispatchers.IO) { environment.snapshots.load() }
            val engine = withContext(Dispatchers.IO) {
                runCatching { environment.settings.searchEngine }.getOrDefault(SearchEngine.DEFAULT)
            }
            // Answers already given, read once on the way in.
            withContext(Dispatchers.IO) {
                runCatching { environment.settings.sitePermissions }.getOrNull()
            }?.let { sitePermissions.restore(it) }
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
            pruneThumbnails()
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
                    // Through the core's builder, which is where "a private profile leaves nothing
                    // here" is written down and tested — not open-coded at the call site, where a
                    // forgotten filter would be silent.
                    browser = buildBrowserSnapshot(
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

    /** The private profile, if one is open. There is at most one, as on the Mac. */
    private val SixState.privateProfile: Profile?
        get() = profiles.firstOrNull { it.isPrivate }

    /**
     * A window in the private profile, creating the profile on the first call.
     *
     * One profile for all private windows rather than one each, so two private tabs share a session
     * the way two ordinary tabs do — and closing private browsing ends all of it at once.
     */
    fun newPrivateWindow(url: String? = null) {
        val existing = _state.value.privateProfile
        if (existing != null) {
            // Switching to it as well as opening in it: the column would otherwise land in a strip
            // that is not the one on screen, which reads as the menu item doing nothing.
            _state.update { it.copy(layout = it.layout.setActiveProfile(existing.id)) }
            openColumn(url, profileId = existing.id)
            return
        }
        val profile = Profile(
            id = UUID.randomUUID(),
            name = Profile.PRIVATE_NAME,
            colorHex = Profile.PRIVATE_COLOR_HEX,
            dataStoreId = UUID.randomUUID(),
            isPrivate = true,
        )
        _state.update {
            it.copy(
                profiles = it.profiles + profile,
                layout = it.layout.setActiveProfile(profile.id),
            )
        }
        openColumn(url, profileId = profile.id)
    }

    /** Closes every private window, forgets the profile, and with it the site data. */
    fun closePrivateBrowsing() {
        val current = _state.value
        val profile = current.privateProfile ?: return
        val storeName = WebProfiles.storeName(profile)

        val goneTabs = current.tabs.values.filter { it.profileId == profile.id }
        for (tab in goneTabs) {
            onWindowGone(tab.id)
            LivePages.forget(tab.id)
        }

        val fallback = current.profiles.firstOrNull { !it.isPrivate }?.id
        _state.update { state ->
            var layout = state.layout.removeProfile(profile.id)
            if (fallback != null) layout = layout.setActiveProfile(fallback)
            state.copy(
                profiles = state.profiles.filterNot { it.isPrivate },
                tabs = state.tabs.filterValues { it.profileId != profile.id },
                layout = layout,
            )
        }
        sitePermissions.forgetProfile(profile.id)

        viewModelScope.launch(Dispatchers.IO) { WebProfiles.deletePrivateStore(storeName) }
        save()
    }

    /** Opens a column on the start page, focused, to the right of the focused one. */
    fun openColumn(url: String? = null, profileId: UUID? = null): UUID {
        val id = UUID.randomUUID()
        _state.update { current ->
            val profile = profileId ?: current.layout.activeProfileId
            current.copy(
                layout = current.layout.insertColumn(id, profile),
                tabs = current.tabs + (id to TabState(id, profile, url)),
            )
        }
        save()
        return id
    }

    fun closeColumn(tabId: UUID) {
        onWindowGone(tabId)
        LivePages.forget(tabId)
        viewModelScope.launch(Dispatchers.IO) { environment.thumbnails.remove(tabId) }
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

    /** What the file says the profiles are, for the launch-time sweep. */
    private suspend fun profilesOnFile(): List<Profile> = withContext(Dispatchers.IO) {
        runCatching { environment.snapshots.load()?.browser?.profiles }.getOrNull().orEmpty()
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

    // MARK: Site permissions

    /**
     * A page is asking for a device.
     *
     * Everything about *whether* it may have it is `SitePermissions`, which is the Mac's code and
     * knows nothing about Android. What is added here is the second gate: an allowed site still
     * cannot have the camera until the app has been allowed it, so a yes may have to wait for the
     * system's own question before it reaches the page.
     */
    fun onPagePermissionRequest(
        tabId: UUID,
        asked: List<SitePermission>,
        origin: String?,
        grant: (Boolean) -> Unit,
    ) {
        val current = _state.value
        val profileId = current.tabs[tabId]?.profileId ?: current.layout.activeProfileId
        questionWindowId = tabId

        sitePermissions.decide(asked, origin.orEmpty(), tabId, profileId) { allowed ->
            if (!allowed) return@decide grant(false)

            val needed = SitePermissionBridge.systemPermissions(asked)
                .filterNot { environment.hasSystemPermission(it) }
                .toSet()

            if (needed.isEmpty()) {
                grant(true)
            } else {
                pendingGrant = grant
                _state.update { it.copy(pendingSystemPermissions = needed) }
            }
        }
        publishQuestion()
    }

    /** The bar's two buttons. */
    fun answerPermission(allowed: Boolean) {
        val windowId = questionWindowId ?: return
        sitePermissions.answer(allowed, windowId)
        _state.update { it.copy(permissionRevision = it.permissionRevision + 1) }
    }

    /** The system answered. A page allowed by its user and refused by the OS is still refused. */
    fun onSystemPermissionsResult(granted: Boolean) {
        val grant = pendingGrant
        pendingGrant = null
        _state.update { it.copy(pendingSystemPermissions = emptySet()) }
        grant?.invoke(granted)
    }

    /** A window going takes its unanswered questions with it, answered no. */
    fun onWindowGone(tabId: UUID) {
        sitePermissions.forgetWindow(tabId)
    }

    override fun onCleared() {
        // The hook holds this view model; a dead one drawing into a dead scope is a leak with a
        // bitmap attached.
        LivePages.onCapture = null
        // Nothing is going to answer these now, and a request merely dropped leaves a page suspended
        // for as long as it lives.
        pageDialogs.cancelAll()
        environment.close()
        super.onCleared()
    }

    /** Every site with a remembered answer, for the panel. */
    fun permissionSites(): List<PermissionSite> = sitePermissions.sites

    fun permissionDecisions(site: PermissionSite): Map<SitePermission, Boolean> =
        sitePermissions.decisions(site.origin, site.profileId)

    /** Take it back: the site asks again the next time it needs the device. */
    fun forgetPermissions(site: PermissionSite) {
        sitePermissions.forget(site.origin, site.profileId)
        _state.update { it.copy(permissionRevision = it.permissionRevision + 1) }
    }

    private fun publishQuestion() {
        val windowId = questionWindowId
        val question = windowId?.let { sitePermissions.question(it) }
        _state.update { current ->
            current.copy(
                permissionQuestion = question?.let {
                    PermissionQuestion(windowId, it.host, it.permissions)
                },
            )
        }
    }

    /**
     * Pictures of windows that no longer exist — closed while the app was not running, or in a
     * launch that never got to clean up. Run once the strip is known and not before, or it would
     * throw away everything on the grounds that nothing has been restored yet.
     */
    private fun pruneThumbnails() {
        val ids = _state.value.tabs.keys
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { environment.thumbnails.prune(ids) }
        }
    }

    /** The picture of a window, read off disk the first time a card asks for it. */
    suspend fun thumbnail(tabId: UUID): androidx.compose.ui.graphics.ImageBitmap? =
        withContext(Dispatchers.IO) { environment.thumbnails.read(tabId) }

    // MARK: Bookmarks

    /**
     * Saves the focused window's page: the row, the passages and the readable Markdown file.
     *
     * The text is read out of the live page rather than fetched again, which is the whole reason
     * this is a browser feature and not a scraper — what is saved is the page as it was being read,
     * including whatever it needed a session for.
     *
     * A discarded column cannot be saved. Loading it in order to save it would be a page request
     * nobody asked for, so this says so instead.
     */
    fun addBookmark() {
        val current = _state.value
        val tabId = current.layout.focusedTabId ?: return
        val tab = current.tabs[tabId] ?: return
        val url = tab.url
        if (url == null) {
            return notify(BookmarkNotice.NOTHING_LOADED)
        }
        if (isPrivate(tab.profileId)) {
            return notify(BookmarkNotice.PRIVATE)
        }
        val profileName = current.profiles.firstOrNull { it.id == tab.profileId }?.name
            ?: return notify(BookmarkNotice.FAILED)

        LivePages.evaluate(tabId, ReadablePage.script) { json ->
            val page = json?.let { ReadablePage.from(it) }
            if (page == null) {
                notify(BookmarkNotice.NO_TEXT)
                return@evaluate
            }
            viewModelScope.launch(Dispatchers.IO) {
                val saved = runCatching {
                    environment.bookmarks.save(page, url, tab.title, tab.profileId, profileName)
                }
                _state.update {
                    it.copy(
                        bookmarkRevision = it.bookmarkRevision + 1,
                        bookmarkNotice = if (saved.isSuccess) null else BookmarkNotice.FAILED,
                    )
                }
            }
        }
    }

    /** Reading them is disk work, like the history, and does not belong on the main thread. */
    suspend fun bookmarks(scope: BookmarkScope = BookmarkScope.PROFILE): List<Bookmark> =
        withContext(Dispatchers.IO) {
            runCatching {
                environment.bookmarks.entries(_state.value.layout.activeProfileId, scope)
            }.getOrDefault(emptyList())
        }

    fun removeBookmark(id: UUID) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching { environment.bookmarks.remove(id) }
            _state.update { it.copy(bookmarkRevision = it.bookmarkRevision + 1) }
        }
    }

    fun clearBookmarkNotice() {
        _state.update { it.copy(bookmarkNotice = null) }
    }

    private fun notify(notice: String) {
        _state.update { it.copy(bookmarkNotice = notice) }
    }

    // MARK: What a page puts up

    fun askPageDialog(request: PageDialogRequest, answer: (PageDialogAnswer) -> Unit) {
        pageDialogs.ask(request, answer)
    }

    fun answerPageDialog(id: UUID, answer: PageDialogAnswer) {
        pageDialogs.resolve(id, answer)
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
        if (!isPrivate(tab.profileId)) {
            viewModelScope.launch(Dispatchers.IO) {
                environment.history.record(url, tab.title, tab.profileId)
            }
        }
        save()
    }

    /**
     * The page did not load. The engine shows its own error page either way; this is so the browser
     * knows, which is what makes a failure something that can be said out loud rather than a window
     * that quietly shows nothing.
     */
    fun onLoadFailed(tabId: UUID, code: Int, description: String) {
        android.util.Log.w("six", "load failed in $tabId: $code $description")
        _state.update { current ->
            val tab = current.tabs[tabId] ?: return@update current
            current.copy(tabs = current.tabs + (tabId to tab.copy(isLoading = false)))
        }
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
        if (!isPrivate(tab.profileId)) {
            viewModelScope.launch(Dispatchers.IO) {
                environment.history.updateTitle(title, url, tab.profileId)
            }
        }
        save()
    }

}
