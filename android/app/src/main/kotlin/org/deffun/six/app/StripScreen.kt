package org.deffun.six.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.deffun.six.R
import java.util.UUID
import org.deffun.six.core.Along
import org.deffun.six.core.NiriLayout
import org.deffun.six.core.Rect
import org.deffun.six.core.Size
import org.deffun.six.core.StripAxis

/**
 * The strip.
 *
 * Columns are placed absolutely from [NiriLayout.columnFrames] rather than by a Compose list,
 * because the geometry is the shared artefact and a lazy row would quietly own it instead. What this
 * file decides is only which way the frames point ([StripAxis]) and what a finger does to them.
 */
@Composable
fun StripScreen(
    viewModel: SixViewModel,
    onExit: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val density = LocalDensity.current

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val viewportDp = Size(maxWidth.value.toDouble(), maxHeight.value.toDouble())
        val axis = StripAxis.of(viewportDp)

        // Measured in dp, because NiriLayout's floors are the Mac's points. See the view model.
        LaunchedEffect(viewportDp) { viewModel.onViewportChanged(axis.stripSpace(viewportDp)) }

        val layout = state.layout
        val workspace = layout.focusedWorkspace
        if (workspace == null || !state.isRestored) return@BoxWithConstraints

        val scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview

        // Which columns get a real WebView. Everything else in the strip is a card, and coming back
        // to it is a restore rather than a fresh request. See LivePages.
        //
        // Under memory pressure the budget collapses to the window being read. Everything else keeps
        // its address, its history and its place — which is the whole point of the strip being a
        // layout rather than a list of live pages.
        val liveTabIds = if (state.isUnderMemoryPressure) {
            setOfNotNull(layout.focusedTabId)
        } else {
            layout.visibleTabIds
        }

        // Back is the page's before it is the app's, which is what makes this a browser rather than
        // an app with a web view in it. The address field takes it first, since a keyboard is open.
        BackHandler(enabled = true) {
            when {
                state.editingTabId != null -> viewModel.cancelEditing()
                LivePages.goBack(layout.focusedTabId) -> Unit
                else -> onExit()
            }
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surfaceVariant)
                // The overview, which on a phone only rescales the strip — the same as the iPhone,
                // where there is no grid behind it yet. `overviewScale` is the layout's own number,
                // and `visibleWidth` already divides by it, so the arithmetic underneath does not
                // change: only how much of it is on screen.
                .graphicsLayer {
                    val scale = layout.overviewScale.toFloat()
                    scaleX = scale
                    scaleY = scale
                },
        ) {
            // The workspace on screen and its two neighbours.
            //
            // Drawing the neighbours is what makes the across-drag mean anything: without them
            // `verticalPreview` moves a screen with nothing on it to move, and the gesture only
            // becomes visible at the moment it commits. Their pages are deliberately not live —
            // `visibleTabIds` never names them — so a workspace arriving is cards, and building web
            // views for a gesture that has not decided where it lands is the worst possible moment
            // to spend that.
            val acrossStep = layout.viewport.height + layout.workspaceSpacing

            for (offset in -1..1) {
                val index = layout.focusedWorkspaceIndex + offset
                val neighbour = layout.workspaces.getOrNull(index) ?: continue
                // Plus, not minus. Along the strip the columns are drawn at
                // `frame.x - (offset - horizontalPreview)`, so a positive band moves content the way
                // the finger went; across it has to do the same or the two axes would disagree —
                // the strip following the finger and the workspaces running away from it. It also
                // has to agree with `commitDrag`, which reads a positive band as revealing what
                // comes *before*.
                val across = offset * acrossStep + layout.verticalPreview
                val isFocusedWorkspace = offset == 0
                val scroll = layout.resolvedOffset(neighbour) -
                    (if (isFocusedWorkspace) layout.horizontalPreview else 0.0)

                layout.columnFrames(neighbour).forEachIndexed { columnIndex, frame ->
                    val column = neighbour.columns.getOrNull(columnIndex) ?: return@forEachIndexed
                    val tab = state.tabs[column.tabId]
                    val placed = axis.screenRect(frame.translated(along = -scroll, across = across))
                    val profile = state.profiles.firstOrNull { it.id == tab?.profileId }

                    ColumnWindow(
                        tabId = column.tabId,
                        frame = placed,
                        isLive = column.tabId in liveTabIds,
                        title = tab?.title.orEmpty(),
                        url = tab?.url,
                        profileStoreName = profile?.let { WebProfiles.storeName(it) },
                        accent = profileColor(profile?.colorHex),
                        isLoading = tab?.isLoading == true,
                        isFocused = isFocusedWorkspace && columnIndex == neighbour.focus,
                        isEditing = state.editingTabId == column.tabId,
                        axis = axis,
                        onTap = { viewModel.handleTapped(column.tabId) },
                        onSubmit = { viewModel.submitAddress(column.tabId, it) },
                        onCancel = { viewModel.cancelEditing() },
                        onClose = { viewModel.closeColumn(column.tabId) },
                        onDrag = { alongDelta, acrossDelta -> viewModel.previewDrag(alongDelta, acrossDelta) },
                        onDragEnd = { viewModel.commitDrag() },
                        onDragCancel = { viewModel.endDrag() },
                        onPageStarted = { viewModel.onPageStarted(column.tabId, it) },
                        onTitleChanged = { viewModel.onTitleChanged(column.tabId, it) },
                        onHistoryChanged = { back, forward ->
                            viewModel.onHistoryChanged(column.tabId, back, forward)
                        },
                        onPageFinished = { viewModel.onPageFinished(column.tabId) },
                    )
                }
            }

            WorkspaceIndicator(
                count = layout.workspaces.size,
                focused = layout.focusedWorkspaceIndex,
                axis = axis,
                onSelect = { viewModel.focusWorkspaceAt(it) },
                modifier = Modifier.align(
                    if (axis.along == Along.X) Alignment.CenterEnd else Alignment.BottomCenter,
                ),
            )
        }
    }
}

/**
 * Where you are in the stack of workspaces, and a way back to any of them.
 *
 * It sits across the strip — down the right edge when the strip runs sideways, along the bottom when
 * it runs down the screen — because that is the direction it describes. The last workspace is always
 * the empty one niri keeps at the end, so the final pip is a place to put something rather than
 * somewhere you have been.
 */
@Composable
private fun WorkspaceIndicator(
    count: Int,
    focused: Int,
    axis: StripAxis,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val pip: @Composable (Int) -> Unit = { index ->
        Box(
            modifier = Modifier
                .padding(4.dp)
                .size(if (index == focused) 10.dp else 6.dp)
                .clip(CircleShape)
                .background(
                    if (index == focused) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.outlineVariant,
                )
                .pointerInput(index) { detectTapGestures { onSelect(index) } },
        )
    }

    if (axis.along == Along.X) {
        Column(
            modifier = modifier.padding(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            repeat(count) { pip(it) }
        }
    } else {
        Row(
            modifier = modifier.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(count) { pip(it) }
        }
    }
}

/**
 * A profile's colour, as `#RRGGBB` in the file the Mac wrote.
 *
 * A profile with no colour, or one written in a form this cannot read, gets the theme's accent
 * rather than a crash or black: the colour is decoration, and the profile still has to work.
 */
@Composable
private fun profileColor(hex: String?): Color {
    val fallback = MaterialTheme.colorScheme.primary
    if (hex == null) return fallback
    return runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(fallback)
}

/** Strip-space translation, before the axis turns it into a screen rectangle. */
private fun Rect.translated(along: Double, across: Double) =
    copy(x = x + along, y = y + across)

@Composable
private fun ColumnWindow(
    tabId: UUID,
    frame: Rect,
    isLive: Boolean,
    title: String,
    url: String?,
    accent: Color,
    isLoading: Boolean,
    profileStoreName: String?,
    isFocused: Boolean,
    isEditing: Boolean,
    axis: StripAxis,
    onTap: () -> Unit,
    onSubmit: (String) -> Unit,
    onCancel: () -> Unit,
    onClose: () -> Unit,
    onDrag: (along: Double, across: Double) -> Unit,
    onDragEnd: () -> Unit,
    onDragCancel: () -> Unit,
    onPageStarted: (String) -> Unit,
    onTitleChanged: (String) -> Unit,
    onHistoryChanged: (Boolean, Boolean) -> Unit,
    onPageFinished: () -> Unit,
) {
    val density = LocalDensity.current
    val shape = RoundedCornerShape(16.dp)

    Box(
        modifier = Modifier
            .offset {
                with(density) { IntOffset(frame.x.dp.roundToPx(), frame.y.dp.roundToPx()) }
            }
            .size(width = frame.width.dp, height = frame.height.dp)
            // The window's own chrome, matching the phone's: a rounded card, a border that takes
            // the profile's colour when this is the window being read, a shadow that says which one
            // that is, and everything else half a step back.
            .alpha(if (isFocused) 1f else 0.92f)
            .shadow(
                elevation = if (isFocused) 14.dp else 8.dp,
                shape = shape,
                clip = false,
            )
            .clip(shape)
            .background(MaterialTheme.colorScheme.surface)
            .border(
                width = if (isFocused) 2.dp else 1.dp,
                color = if (isFocused) accent else MaterialTheme.colorScheme.outlineVariant,
                shape = shape,
            ),
    ) {
        Box(modifier = Modifier.fillMaxSize().padding(top = HandleHeight)) {
            when {
                url == null -> StartPage()
                isLive -> PageView(
                    tabId = tabId,
                    url = url,
                    profileStoreName = profileStoreName,
                    onPageStarted = onPageStarted,
                    onTitleChanged = onTitleChanged,
                    onHistoryChanged = onHistoryChanged,
                    onPageFinished = onPageFinished,
                )
                // Leaving the composition is what discards the page: `onRelease` saves its bundle.
                else -> DiscardedPage(title = title, url = url)
            }
        }

        ColumnHandle(
            title = title,
            url = url,
            accent = accent,
            isLoading = isLoading,
            isFocused = isFocused,
            isEditing = isEditing,
            axis = axis,
            onTap = onTap,
            onSubmit = onSubmit,
            onCancel = onCancel,
            onClose = onClose,
            onDrag = onDrag,
            onDragEnd = onDragEnd,
            onDragCancel = onDragCancel,
        )
    }
}

/**
 * A column whose page has been discarded.
 *
 * It is still a window in the strip — the address, the title and its place are all still here — and
 * scrolling back to it builds the page again. The Mac also keeps a picture of the page; capturing a
 * bitmap per column is a memory decision that should not be made without being able to measure it,
 * so this is text for now.
 */
@Composable
private fun DiscardedPage(title: String, url: String) {
    Box(
        modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerLow),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = title.ifEmpty { url },
                style = MaterialTheme.typography.titleSmall,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            Text(
                text = host(url),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

private fun host(url: String): String =
    runCatching { java.net.URI(url).host }.getOrNull() ?: url

@Composable
private fun StartPage() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = stringResource(R.string.address_hint),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
