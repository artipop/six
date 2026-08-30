package org.deffun.six.core

import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.round

/**
 * niri-style scrollable tiling: columns laid out along a workspace, workspaces stacked across it.
 * Owns geometry (column widths, strip scroll offset) and the focus/move operations; what the columns
 * point at is somebody else's.
 *
 * ## Why this is a value and not an object
 *
 * The Mac's `NiriLayout` is an `@Observable` class that mutates in place. Here it is an immutable
 * data class and every operation returns a new one, because that is what Compose wants: one
 * `StateFlow<NiriLayout>` in a ViewModel, recomposition driven by equality, and transitions that are
 * pure functions a JVM test can call without a device or a scheduler.
 *
 * The *numbers* are not free to differ. Every constant, every rounding and every clamp below is the
 * Mac's, because `state.json` is written by one front end and read by another and a strip that lays
 * itself out differently on two devices is a strip that lost its place. `NiriLayoutGeometryTest` is
 * the port of the Mac's own suite and exists to hold exactly that line.
 *
 * Two things deliberately did not come across:
 *
 * - **Animation.** The model's business is *when* something should ease rather than jump; how it
 *   eases belongs to whoever draws it. On the Mac that is SwiftUI's `withAnimation`; here it is an
 *   `Animatable` in the composable, so `peek()` — the strip's lean to the right when a window opens
 *   behind — lives in the UI layer and writes [horizontalPreview] the same way a gesture does.
 * - **Display strings.** `widthPresetTitles` and `title(at:)` return localised text on the Mac.
 *   Android localises through `strings.xml`, so [WIDTH_PRESET_KEYS] are keys and [workspaceName]
 *   returns null rather than inventing "Workspace 3" — the same split the Linux front already makes.
 */
data class NiriLayout(
    val viewport: Size = Size(1280.0, 800.0),
    val isOverview: Boolean = false,
    /**
     * niri's fullscreen, as a mode rather than per-window state — and one step short of it, filling
     * the window instead of the screen. Either way the strip goes on working underneath.
     */
    val fill: NiriFill = NiriFill.TILED,
    /**
     * niri's `center-focused-column`: park the focused window in the middle of the screen instead of
     * scrolling as little as possible. Off means the strip only moves when focus would fall off it.
     */
    val centersFocus: Boolean = true,
    /**
     * The preset every window uses; new windows open with it. Unlike niri this is one value for the
     * whole app, not per column — a strip where each window has its own width reads as a mess.
     */
    val preferredWidthIndex: Int = DEFAULT_WIDTH_INDEX,
    /** Rubber-band offsets while a gesture is still below the switch threshold. */
    val verticalPreview: Double = 0.0,
    val horizontalPreview: Double = 0.0,
    val activeProfileId: UUID = UUID.randomUUID(),
    val strips: Map<UUID, NiriStrip> = emptyMap(),
) {

    companion object {
        /**
         * Column widths, as a fraction of the working area — niri's `preset-column-widths`. The
         * default is "almost full": a normal browser window, with the next one peeking in at the edge.
         */
        val WIDTH_PRESETS = listOf(0.5, 2.0 / 3.0, 0.88, 1.0)

        /** Keys for the presets, in the same order; the UI resolves them against `strings.xml`. */
        val WIDTH_PRESET_KEYS = listOf("half", "two_thirds", "peek", "full")

        const val DEFAULT_WIDTH_INDEX = 2

        /**
         * Gaps are a fraction of the viewport, not a pixel count: the layout should look the same on
         * a phone and on a tablet. The floor only guards tiny windows. (Control metrics — title bar
         * heights, buttons, corner radii — stay in dp, because text and controls don't scale either.)
         */
        const val GAP_FRACTION = 0.01
        const val MINIMUM_GAP = 10.0

        /**
         * How far the overview zooms out: enough to show the whole focused strip, but never more
         * than [OVERVIEW_BASE_SCALE] and never past the floor, where a long strip starts scrolling
         * instead of getting microscopic.
         */
        const val OVERVIEW_BASE_SCALE = 0.5
        const val MINIMUM_OVERVIEW_SCALE = 0.22

        /** Breathing room between workspaces, as a fraction of the viewport across the strip. */
        const val WORKSPACE_GAP_FRACTION = 0.02
        const val OVERVIEW_WORKSPACE_GAP_FRACTION = 0.11

        /**
         * How far a drag has to travel before letting go steps rather than springs back — a
         * fraction of the viewport, for the same reason the gaps are.
         */
        const val DRAG_COMMIT_FRACTION = 0.15

        private const val MINIMUM_USABLE_WIDTH = 360.0
        private const val MINIMUM_COLUMN_WIDTH = 280.0
        private const val MINIMUM_COLUMN_HEIGHT = 200.0
    }

    // MARK: - Access

    val strip: NiriStrip get() = strips[activeProfileId] ?: NiriStrip()
    val workspaces: List<NiriWorkspace> get() = strip.workspaces
    val focusedWorkspaceIndex: Int
        get() = strip.focus.coerceIn(0, max(0, strip.workspaces.size - 1))
    val focusedWorkspace: NiriWorkspace? get() = strip.workspaces.getOrNull(strip.focus)
    val focusedTabId: UUID? get() = focusedWorkspace?.focusedColumn?.tabId
    val hasColumns: Boolean get() = strip.workspaces.any { !it.isEmpty }

    /** Is there a column that way? Drives the on-screen edge buttons. */
    fun canFocusColumn(delta: Int): Boolean {
        val ws = focusedWorkspace ?: return false
        return (ws.focus + delta) in ws.columns.indices
    }

    fun canFocusWorkspace(delta: Int): Boolean =
        (strip.focus + delta) in strip.workspaces.indices

    /** Any profile's strip, not just the one on screen. */
    fun stripFor(profileId: UUID): NiriStrip = strips[profileId] ?: NiriStrip()

    /**
     * Distance between two workspaces across the strip. Only visible mid-switch — and in the
     * overview, where it is opened up so the neighbours read as separate screens.
     */
    val workspaceSpacing: Double
        get() = viewport.height *
            (if (isOverview) OVERVIEW_WORKSPACE_GAP_FRACTION else WORKSPACE_GAP_FRACTION)

    // MARK: - Geometry

    /**
     * The overview is another way of looking at the same strip, so filling steps aside while it is
     * open — with the gaps and the title bars back, the columns can be told apart.
     */
    val showsFill: NiriFill get() = if (isOverview) NiriFill.TILED else fill

    /** One column, one screen: no gaps and no title bars, in both filling modes. */
    val fillsViewport: Boolean get() = showsFill != NiriFill.TILED

    /** Only fullscreen takes the top bar with it. */
    val showsFullscreen: Boolean get() = showsFill == NiriFill.SCREEN

    /**
     * Space between two columns, and between a column and the edge of the screen. Fullscreen has
     * none: the page runs to every edge, and the next window starts exactly one screen away.
     *
     * `round` here is Kotlin's — ties toward positive infinity — where the Mac's `rounded()` ties
     * away from zero. The argument is `viewport.width * 0.01` and so never negative, which is the
     * only case where the two disagree.
     */
    val gap: Double
        get() = if (fillsViewport) 0.0 else max(MINIMUM_GAP, round(viewport.width * GAP_FRACTION))

    val outerGap: Double get() = gap

    /** Working area, with one gap folded in so N columns of 1/N exactly fill the screen. */
    private val usableWidth: Double
        get() = max(MINIMUM_USABLE_WIDTH, viewport.width - 2 * outerGap + gap)

    val columnHeight: Double
        get() = max(MINIMUM_COLUMN_HEIGHT, viewport.height - 2 * outerGap)

    /** Scale of the whole canvas: 1 normally, zoomed out in the overview. */
    val overviewScale: Double
        get() {
            if (!isOverview) return 1.0
            val workspace = focusedWorkspace
            if (workspace == null || workspace.isEmpty) return OVERVIEW_BASE_SCALE
            val fitting = viewport.width / contentWidth(workspace)
            return min(OVERVIEW_BASE_SCALE, max(MINIMUM_OVERVIEW_SCALE, fitting))
        }

    /**
     * Width of what the viewport actually shows, in content points. The overview scales the canvas
     * down, so it shows proportionally more of the strip — and scrolls when even that isn't enough.
     */
    val visibleWidth: Double get() = viewport.width / overviewScale

    /**
     * Filling overrides the preset without touching it: the widths are all still there on the way out.
     */
    fun width(column: NiriColumn): Double {
        if (fillsViewport) return viewport.width
        val fraction = WIDTH_PRESETS[column.widthIndex.coerceIn(0, WIDTH_PRESETS.size - 1)]
        return max(MINIMUM_COLUMN_WIDTH, usableWidth * fraction - gap)
    }

    /** Column rectangles in content space (x grows along the strip, origin at the strip's start). */
    fun columnFrames(workspace: NiriWorkspace): List<Rect> {
        val frames = ArrayList<Rect>(workspace.columns.size)
        var x = outerGap
        for (column in workspace.columns) {
            val w = width(column)
            frames.add(Rect(x = x, y = outerGap, width = w, height = columnHeight))
            x += w + gap
        }
        return frames
    }

    fun contentWidth(workspace: NiriWorkspace): Double {
        if (workspace.columns.isEmpty()) return 0.0
        val widths = workspace.columns.sumOf { width(it) }
        return widths + gap * (workspace.columns.size - 1) + 2 * outerGap
    }

    /**
     * Where the focused column is on screen right now, in the strip's own coordinates. The controls
     * that belong to the focused window are placed against it rather than against the window, so
     * they stand in the gap the layout already leaves.
     */
    val focusedColumnFrame: Rect?
        get() {
            if (isOverview) return null
            val workspace = focusedWorkspace ?: return null
            val frames = columnFrames(workspace)
            val frame = frames.getOrNull(workspace.focus) ?: return null
            return frame.copy(x = frame.x - (resolvedOffset(workspace) - horizontalPreview))
        }

    /**
     * The windows the strip is actually showing: the focused workspace's columns that fall inside
     * the viewport, plus half a screen of margin on each side so stepping to a neighbour has its
     * page ready. This is what gets a real web view and what the live-page budget pins.
     *
     * Workspaces across the strip are deliberately not in here, mid-gesture included: building a web
     * view costs a hitch you can see, and doing it for a whole workspace while a gesture is still
     * deciding where to land is the worst possible moment for it.
     */
    val visibleTabIds: Set<UUID>
        get() {
            val workspace = focusedWorkspace ?: return emptySet()
            if (workspace.isEmpty) return emptySet()
            val frames = columnFrames(workspace)
            val scroll = resolvedOffset(workspace) - horizontalPreview
            val margin = visibleWidth / 2
            val ids = LinkedHashSet<UUID>()
            workspace.columns.forEachIndexed { index, column ->
                val frame = frames.getOrNull(index) ?: return@forEachIndexed
                val x = frame.minX - scroll
                if (x + frame.width > -margin && x < visibleWidth + margin) ids.add(column.tabId)
            }
            return ids
        }

    private fun centeredOffset(frame: Rect): Double = frame.midX - visibleWidth / 2

    /**
     * How far the strip may scroll. While centring, the ends are reached when the first/last window
     * sits in the middle, so every window can get there — otherwise the strip stops at its edges.
     */
    private fun offsetBounds(workspace: NiriWorkspace): ClosedFloatingPointRange<Double> {
        val width = visibleWidth
        val frames = columnFrames(workspace)
        val first = frames.firstOrNull()
        val last = frames.lastOrNull()
        // The overview shows strips, not a focused window: it scrolls freely and centres what fits.
        if (centersFocus && !isOverview && first != null && last != null) {
            val lower = centeredOffset(first)
            return lower..max(lower, centeredOffset(last))
        }
        val total = contentWidth(workspace)
        if (total <= width) {
            val centred = (total - width) / 2 // the whole strip fits: centre it
            return centred..centred
        }
        return 0.0..(total - width)
    }

    private fun clampOffset(offset: Double, workspace: NiriWorkspace): Double {
        val bounds = offsetBounds(workspace)
        return offset.coerceIn(bounds.start, bounds.endInclusive)
    }

    /** Scroll position actually used for drawing. */
    fun resolvedOffset(workspace: NiriWorkspace): Double =
        clampOffset(workspace.viewOffset, workspace)

    /** Centres the focused column, or — with centring off — scrolls the least it can to reveal it. */
    private fun scrollFocusIntoView(workspace: NiriWorkspace): NiriWorkspace {
        val frames = columnFrames(workspace)
        val frame = frames.getOrNull(workspace.focus) ?: return workspace
        if (centersFocus) {
            return workspace.copy(viewOffset = clampOffset(centeredOffset(frame), workspace))
        }
        val total = contentWidth(workspace)
        if (total <= visibleWidth) {
            return workspace.copy(viewOffset = (total - visibleWidth) / 2)
        }
        var offset = clampOffset(workspace.viewOffset, workspace)
        if (frame.minX - outerGap < offset) offset = frame.minX - outerGap
        if (frame.maxX + outerGap > offset + visibleWidth) offset = frame.maxX + outerGap - visibleWidth
        return workspace.copy(viewOffset = clampOffset(offset, workspace))
    }

    // MARK: - Transitions

    private fun mutate(profileId: UUID = activeProfileId, body: (NiriStrip) -> NiriStrip): NiriLayout {
        val next = normalize(body(strips[profileId] ?: NiriStrip()))
        return copy(strips = strips + (profileId to next))
    }

    private fun mutateWorkspace(index: Int, body: (NiriWorkspace) -> NiriWorkspace): NiriLayout =
        mutate { s ->
            val ws = s.workspaces.getOrNull(index) ?: return@mutate s
            s.copy(workspaces = s.workspaces.replacing(index, body(ws)))
        }

    private fun mutateFocusedWorkspace(body: (NiriWorkspace) -> NiriWorkspace): NiriLayout =
        mutateWorkspace(strip.focus, body)

    /**
     * Keeps exactly one trailing empty workspace and drops the empty ones in between — niri's
     * dynamic workspaces. A named workspace stays even when it is empty, also like niri.
     */
    private fun normalize(s: NiriStrip): NiriStrip {
        val focusedId = s.workspaces.getOrNull(s.focus)?.id
        val kept = s.workspaces.filter { !it.isEmpty || it.name.isNotEmpty() }.toMutableList()
        val trailing = s.workspaces.lastOrNull()
        if (trailing != null && trailing.isEmpty && trailing.name.isEmpty()) {
            kept.add(trailing) // reuse its identity so focus survives the prune
        } else {
            kept.add(NiriWorkspace())
        }
        for (i in kept.indices) {
            val ws = kept[i].let { it.copy(focus = it.focus.coerceIn(0, max(0, it.columns.size - 1))) }
            kept[i] = ws.copy(viewOffset = clampOffset(ws.viewOffset, ws))
        }
        val focus = kept.indexOfFirst { it.id == focusedId }
            .takeIf { it >= 0 }
            ?: s.focus.coerceIn(0, kept.size - 1)
        return NiriStrip(workspaces = kept, focus = focus)
    }

    /** Puts every workspace of one strip back under its focused window. */
    private fun recenterStrip(profileId: UUID): NiriLayout =
        mutate(profileId) { s ->
            s.copy(workspaces = s.workspaces.map { scrollFocusIntoView(it) })
        }

    /**
     * Every strip, not just the one on screen: the viewport, the centring switch and fullscreen all
     * belong to the window, so a strip left alone would still be scrolled for the geometry it last saw.
     */
    fun recenterStrips(): NiriLayout {
        var result = this
        for (profileId in strips.keys.toList()) result = result.recenterStrip(profileId)
        return result.recenterStrip(activeProfileId)
    }

    /**
     * Replaces every strip with saved ones (normalised, so a stale file can't leave a strip without
     * its trailing empty workspace or with a focus out of range).
     */
    fun restore(saved: Map<UUID, NiriStrip>): NiriLayout {
        var result = copy(strips = emptyMap())
        for ((profileId, strip) in saved) result = result.mutate(profileId) { strip }
        // the offsets on disk were written for whatever viewport wrote them
        return result.recenterStrips()
    }

    /** Switching profile shows a strip last laid out at another viewport, so it is put back first. */
    fun setActiveProfile(profileId: UUID): NiriLayout =
        if (profileId == activeProfileId) this
        else copy(activeProfileId = profileId).recenterStrip(profileId)

    fun setCentersFocus(value: Boolean): NiriLayout =
        copy(centersFocus = value).recenterStrips()

    /** Every column changes width here, so every offset that pointed at one has to be found again. */
    fun setFill(value: NiriFill): NiriLayout =
        if (value == fill) this else copy(fill = value).recenterStrips()

    fun setOverview(value: Boolean): NiriLayout =
        if (value == isOverview) this else copy(isOverview = value).recenterStrips()

    fun updateViewport(size: Size): NiriLayout {
        if (size.width <= 1 || size.height <= 1 || size == viewport) return this
        return copy(viewport = size).recenterStrips()
    }

    fun removeProfile(profileId: UUID): NiriLayout = copy(strips = strips - profileId)

    // MARK: - Columns

    /** Opens a tab as a new column to the right of the focused one, niri-style. */
    fun insertColumn(tabId: UUID): NiriLayout = insertColumn(tabId, activeProfileId)

    /**
     * Opens a tab in a given workspace of a given profile's strip. [workspace] defaults to the
     * strip's focused one; with [focus] off the window is added right of the focused column but
     * nothing on screen moves.
     */
    fun insertColumn(
        tabId: UUID,
        profileId: UUID,
        workspace: Int? = null,
        focus: Boolean = true,
    ): NiriLayout = mutate(profileId) { s ->
        val target = (workspace ?: s.focus).coerceIn(0, s.workspaces.size - 1)
        val ws = s.workspaces.getOrNull(target) ?: return@mutate s
        val index = if (ws.columns.isEmpty()) 0 else ws.focus + 1
        val at = min(index, ws.columns.size)
        var next = ws.copy(
            columns = ws.columns.inserting(at, NiriColumn(tabId, preferredWidthIndex)),
        )
        if (!focus) return@mutate s.copy(workspaces = s.workspaces.replacing(target, next))
        next = scrollFocusIntoView(next.copy(focus = min(at, next.columns.size - 1)))
        s.copy(workspaces = s.workspaces.replacing(target, next), focus = target)
    }

    fun removeColumn(tabId: UUID): NiriLayout = mutate { s ->
        val w = s.workspaces.indexOfFirst { ws -> ws.columns.any { it.tabId == tabId } }
        if (w < 0) return@mutate s
        val ws = s.workspaces[w]
        val index = ws.columns.indexOfFirst { it.tabId == tabId }
        val columns = ws.columns.removing(index)
        val next = scrollFocusIntoView(
            ws.copy(columns = columns, focus = min(index, max(0, columns.size - 1))),
        )
        s.copy(workspaces = s.workspaces.replacing(w, next))
    }

    fun focus(tabId: UUID): NiriLayout = mutate { s ->
        val w = s.workspaces.indexOfFirst { ws -> ws.columns.any { it.tabId == tabId } }
        if (w < 0) return@mutate s
        val ws = s.workspaces[w]
        val index = ws.columns.indexOfFirst { it.tabId == tabId }
        s.copy(
            workspaces = s.workspaces.replacing(w, scrollFocusIntoView(ws.copy(focus = index))),
            focus = w,
        )
    }

    fun focusColumn(delta: Int): NiriLayout = mutateFocusedWorkspace { ws ->
        if (ws.columns.isEmpty()) ws
        else scrollFocusIntoView(ws.copy(focus = (ws.focus + delta).coerceIn(0, ws.columns.size - 1)))
    }

    fun focusColumnEdge(last: Boolean): NiriLayout = mutateFocusedWorkspace { ws ->
        if (ws.columns.isEmpty()) ws
        else scrollFocusIntoView(ws.copy(focus = if (last) ws.columns.size - 1 else 0))
    }

    /** Swaps the focused column with its neighbour and follows it. */
    fun moveColumn(delta: Int): NiriLayout = mutateFocusedWorkspace { ws ->
        val target = ws.focus + delta
        if (ws.focus !in ws.columns.indices || target !in ws.columns.indices) return@mutateFocusedWorkspace ws
        val columns = ws.columns.toMutableList()
        val moved = columns[ws.focus]
        columns[ws.focus] = columns[target]
        columns[target] = moved
        scrollFocusIntoView(ws.copy(columns = columns, focus = target))
    }

    /** Moves a column, wherever it is in the profile's strip, to a workspace by index. */
    fun moveColumn(tabId: UUID, profileId: UUID, toWorkspace: Int): NiriLayout =
        mutate(profileId) { s ->
            val target = toWorkspace
            val from = s.workspaces.indexOfFirst { ws -> ws.columns.any { it.tabId == tabId } }
            if (from < 0) return@mutate s
            val at = s.workspaces[from].columns.indexOfFirst { it.tabId == tabId }
            val destinationIndex = max(0, target)
            if (destinationIndex == from) return@mutate s

            val column = s.workspaces[from].columns[at]
            val source = s.workspaces[from].let { ws ->
                val columns = ws.columns.removing(at)
                scrollFocusIntoView(ws.copy(columns = columns, focus = min(ws.focus, max(0, columns.size - 1))))
            }
            val workspaces = s.workspaces.replacing(from, source).toMutableList()
            while (destinationIndex >= workspaces.size) workspaces.add(NiriWorkspace())
            val destination = workspaces[destinationIndex]
            val index = if (destination.columns.isEmpty()) 0 else destination.focus + 1
            workspaces[destinationIndex] = destination.copy(
                columns = destination.columns.inserting(min(index, destination.columns.size), column),
            )
            s.copy(workspaces = workspaces)
        }

    /** One preset wider or narrower, for every window in every strip. Stops at the ends. */
    fun stepColumnWidth(delta: Int): NiriLayout = setPreferredWidth(preferredWidthIndex + delta)

    /** Applies a preset to every window everywhere (a restored setting, or the width action). */
    fun setPreferredWidth(index: Int): NiriLayout {
        val clamped = index.coerceIn(0, WIDTH_PRESETS.size - 1)
        var result = copy(preferredWidthIndex = clamped)
        for (profileId in strips.keys.toList()) {
            result = result.mutate(profileId) { s ->
                s.copy(
                    workspaces = s.workspaces.map { ws ->
                        result.scrollFocusIntoView(
                            ws.copy(columns = ws.columns.map { it.copy(widthIndex = clamped) }),
                        )
                    },
                )
            }
        }
        return result
    }

    /** Is this window at the widest preset (compact width)? */
    fun isFullWidth(tabId: UUID): Boolean =
        strip.workspaces.asSequence().flatMap { it.columns }
            .firstOrNull { it.tabId == tabId }?.widthIndex == WIDTH_PRESETS.size - 1

    val focusedColumnIsFullWidth: Boolean
        get() = focusedWorkspace?.focusedColumn?.widthIndex == WIDTH_PRESETS.size - 1

    /**
     * niri's "maximize column": the widest preset, or back to the default. Still tiled — the gaps and
     * the title bar stay, which is what makes it the compact one next to [NiriFill.WINDOW].
     */
    fun toggleCompactWidth(): NiriLayout = mutateFocusedWorkspace { ws ->
        if (ws.focus !in ws.columns.indices) return@mutateFocusedWorkspace ws
        val full = WIDTH_PRESETS.size - 1
        // Back to the shared preset — unless that is the full width itself, then to the default, so
        // the toggle always has somewhere to go.
        val narrow = if (preferredWidthIndex == full) DEFAULT_WIDTH_INDEX else preferredWidthIndex
        val current = ws.columns[ws.focus]
        val columns = ws.columns.replacing(
            ws.focus,
            current.copy(widthIndex = if (current.widthIndex == full) narrow else full),
        )
        scrollFocusIntoView(ws.copy(columns = columns))
    }

    // MARK: - Strip scrolling

    /**
     * Free panning of the strip, and of the strips in the overview. Refused while centring is on:
     * there the strip only ever rests with the focused window in the middle.
     */
    fun panStrip(delta: Double): NiriLayout {
        if (centersFocus && !isOverview) return this
        return mutateFocusedWorkspace { ws ->
            ws.copy(viewOffset = clampOffset(ws.viewOffset + delta, ws))
        }
    }

    /** After a pan, focus follows the view: the column nearest the middle of the screen wins. */
    fun snapFocusToView(): NiriLayout = mutateFocusedWorkspace { ws ->
        val frames = columnFrames(ws)
        if (frames.isEmpty()) return@mutateFocusedWorkspace ws
        val centre = resolvedOffset(ws) + visibleWidth / 2
        val nearest = frames.indices.minByOrNull { abs(frames[it].midX - centre) } ?: ws.focus
        // the pan ends on a column, never between two
        scrollFocusIntoView(ws.copy(focus = nearest))
    }

    // MARK: - Workspaces

    fun focusWorkspace(delta: Int): NiriLayout =
        mutate { s -> s.copy(focus = (s.focus + delta).coerceIn(0, s.workspaces.size - 1)) }

    fun focusWorkspaceAt(index: Int): NiriLayout =
        mutate { s -> s.copy(focus = index.coerceIn(0, s.workspaces.size - 1)) }

    /** Moves the focused column to the workspace above/below and follows it. */
    fun moveColumnToWorkspace(delta: Int): NiriLayout = mutate { s ->
        val sourceIndex = s.focus
        val ws = s.workspaces.getOrNull(sourceIndex) ?: return@mutate s
        if (ws.focus !in ws.columns.indices) return@mutate s
        val target = sourceIndex + delta
        if (target < 0) return@mutate s

        val column = ws.columns[ws.focus]
        val columns = ws.columns.removing(ws.focus)
        val source = scrollFocusIntoView(
            ws.copy(columns = columns, focus = min(ws.focus, max(0, columns.size - 1))),
        )
        val workspaces = s.workspaces.replacing(sourceIndex, source).toMutableList()
        if (target >= workspaces.size) workspaces.add(NiriWorkspace())

        val destination = workspaces[target]
        val index = min(if (destination.columns.isEmpty()) 0 else destination.focus + 1, destination.columns.size)
        val grown = destination.copy(columns = destination.columns.inserting(index, column))
        workspaces[target] = scrollFocusIntoView(grown.copy(focus = min(index, grown.columns.size - 1)))
        s.copy(workspaces = workspaces, focus = target)
    }

    /**
     * The name of a workspace, or null when it has none — the caller formats the position, because
     * "Workspace 3" is a translated string and this module has no resources.
     */
    fun workspaceName(index: Int): String? = workspaces.getOrNull(index)?.name?.ifEmpty { null }

    fun renameWorkspace(index: Int, name: String): NiriLayout =
        mutateWorkspace(index) { it.copy(name = name.trim()) }

    /**
     * Index of the workspace with this name in a profile's strip, creating it — as the trailing
     * empty workspace, which gets the name and so survives being empty — when there is none.
     *
     * Returns the layout alongside the index because creating one changes the strip; the Mac can
     * return the index alone only because its layout mutates in place.
     */
    fun workspaceIndexNamed(
        name: String,
        profileId: UUID,
        createIfMissing: Boolean,
    ): Pair<NiriLayout, Int?> {
        val wanted = name.trim()
        if (wanted.isEmpty()) return this to null
        val existing = stripFor(profileId).workspaces
        val found = existing.indexOfFirst { it.name.equals(wanted, ignoreCase = true) }
        if (found >= 0) return this to found
        if (!createIfMissing) return this to null

        var created: Int? = null
        val next = mutate(profileId) { s ->
            val last = s.workspaces.lastOrNull()
            val workspaces = if (last != null && last.isEmpty && last.name.isEmpty()) {
                s.workspaces.replacing(s.workspaces.size - 1, last.copy(name = wanted))
            } else {
                s.workspaces + NiriWorkspace(name = wanted)
            }
            created = workspaces.size - 1
            s.copy(workspaces = workspaces)
        }
        return next to created
    }
}

// MARK: - List helpers

private fun <T> List<T>.replacing(index: Int, value: T): List<T> =
    toMutableList().also { it[index] = value }

private fun <T> List<T>.inserting(index: Int, value: T): List<T> =
    toMutableList().also { it.add(index, value) }

private fun <T> List<T>.removing(index: Int): List<T> =
    toMutableList().also { it.removeAt(index) }
