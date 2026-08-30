package org.deffun.six.app

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import org.deffun.six.R
import org.deffun.six.core.NiriLayout
import org.deffun.six.core.Rect
import org.deffun.six.core.Size
import org.deffun.six.core.StripAxis

/** The handle above each window: the address, and the only surface the strip is dragged from. */
private val HandleHeight = 36.dp

/**
 * The strip.
 *
 * Columns are placed absolutely from [NiriLayout.columnFrames] rather than by a Compose list,
 * because the geometry is the shared artefact and a lazy row would quietly own it instead. What this
 * file decides is only which way the frames point ([StripAxis]) and what a finger does to them.
 */
@Composable
fun StripScreen(viewModel: SixViewModel = viewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val density = LocalDensity.current

    BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
        val viewportDp = Size(maxWidth.value.toDouble(), maxHeight.value.toDouble())
        val axis = StripAxis.of(viewportDp)

        // Measured in dp, because NiriLayout's floors are the Mac's points. See the view model.
        LaunchedEffect(viewportDp) { viewModel.onViewportChanged(axis.stripSpace(viewportDp)) }

        val layout = state.layout
        val workspace = layout.focusedWorkspace
        if (workspace == null || !state.isRestored) return@BoxWithConstraints

        val scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            layout.columnFrames(workspace).forEachIndexed { index, frame ->
                val column = workspace.columns.getOrNull(index) ?: return@forEachIndexed
                val tab = state.tabs[column.tabId]
                val placed = axis.screenRect(frame.translatedAlong(-scroll))

                ColumnWindow(
                    frame = placed,
                    title = tab?.title.orEmpty(),
                    url = tab?.url,
                    isFocused = index == workspace.focus,
                    axis = axis,
                    onFocus = { viewModel.focus(column.tabId) },
                    onDrag = { along, across -> viewModel.previewDrag(along, across) },
                    onDragEnd = { viewModel.commitDrag() },
                    onDragCancel = { viewModel.endDrag() },
                    onPageStarted = { viewModel.onPageStarted(column.tabId, it) },
                    onTitleChanged = { viewModel.onTitleChanged(column.tabId, it) },
                )
            }
        }
    }
}

/** Along-space translation, before the axis turns it into a screen rectangle. */
private fun Rect.translatedAlong(delta: Double) = copy(x = x + delta)

@Composable
private fun ColumnWindow(
    frame: Rect,
    title: String,
    url: String?,
    isFocused: Boolean,
    axis: StripAxis,
    onFocus: () -> Unit,
    onDrag: (along: Double, across: Double) -> Unit,
    onDragEnd: () -> Unit,
    onDragCancel: () -> Unit,
    onPageStarted: (String) -> Unit,
    onTitleChanged: (String) -> Unit,
) {
    val density = LocalDensity.current

    Box(
        modifier = Modifier
            .offset {
                with(density) { IntOffset(frame.x.dp.roundToPx(), frame.y.dp.roundToPx()) }
            }
            .size(width = frame.width.dp, height = frame.height.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface),
    ) {
        Box(modifier = Modifier.fillMaxSize().padding(top = HandleHeight)) {
            if (url == null) {
                StartPage()
            } else {
                PageView(
                    url = url,
                    onPageStarted = onPageStarted,
                    onTitleChanged = onTitleChanged,
                )
            }
        }

        // The handle is the address field and the drag surface both, because a phone has no ⌘L and
        // no room for a bar of its own. A tap on a window that is not focused only focuses it, so
        // walking the strip never opens the keyboard.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(HandleHeight)
                .background(
                    if (isFocused) MaterialTheme.colorScheme.surfaceVariant
                    else MaterialTheme.colorScheme.surface,
                )
                // A tap on a window that is not focused only focuses it, so walking the strip never
                // opens the keyboard. (Editing the address on the focused one is the next step.)
                .pointerInput(Unit) {
                    detectTapGestures { onFocus() }
                }
                // And the drag that moves the strip. It lives here rather than on the background
                // because the background is covered by the columns and would almost never be
                // touched — and here it is also, deliberately, not the page.
                .pointerInput(axis) {
                    // Compose reports increments; the rubber band is an absolute displacement.
                    var along = 0.0
                    var across = 0.0
                    detectDragGestures(
                        onDragStart = {
                            along = 0.0
                            across = 0.0
                        },
                        onDragEnd = onDragEnd,
                        onDragCancel = onDragCancel,
                    ) { change, dragAmount ->
                        change.consume()
                        val delta = axis.stripDelta(
                            dx = with(density) { dragAmount.x.toDp().value.toDouble() },
                            dy = with(density) { dragAmount.y.toDp().value.toDouble() },
                        )
                        along += delta.along
                        across += delta.across
                        onDrag(along, across)
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = title.ifEmpty { url ?: stringResource(R.string.start_page_title) },
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 12.dp),
            )
        }
    }
}

@Composable
private fun StartPage() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = stringResource(R.string.address_hint),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
