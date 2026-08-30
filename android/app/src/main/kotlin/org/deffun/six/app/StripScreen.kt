package org.deffun.six.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import org.deffun.six.R
import java.util.UUID
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
    viewModel: SixViewModel = viewModel(),
    onExit: () -> Unit = {},
) {
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
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            layout.columnFrames(workspace).forEachIndexed { index, frame ->
                val column = workspace.columns.getOrNull(index) ?: return@forEachIndexed
                val tab = state.tabs[column.tabId]
                val placed = axis.screenRect(frame.translatedAlong(-scroll))
                val profile = state.profiles.firstOrNull { it.id == tab?.profileId }

                ColumnWindow(
                    tabId = column.tabId,
                    frame = placed,
                    title = tab?.title.orEmpty(),
                    url = tab?.url,
                    profileStoreName = profile?.let { WebProfiles.storeName(it) },
                    isFocused = index == workspace.focus,
                    isEditing = state.editingTabId == column.tabId,
                    axis = axis,
                    onTap = { viewModel.handleTapped(column.tabId) },
                    onSubmit = { viewModel.submitAddress(column.tabId, it) },
                    onCancel = { viewModel.cancelEditing() },
                    onClose = { viewModel.closeColumn(column.tabId) },
                    onDrag = { along, across -> viewModel.previewDrag(along, across) },
                    onDragEnd = { viewModel.commitDrag() },
                    onDragCancel = { viewModel.endDrag() },
                    onPageStarted = { viewModel.onPageStarted(column.tabId, it) },
                    onTitleChanged = { viewModel.onTitleChanged(column.tabId, it) },
                )
            }

            // The Mac grows the strip from the `+` that the right-hand sliver becomes at its end,
            // which needs a pointer hovering a two-point gap. This is the placeholder for that
            // gesture, not a considered answer to it.
            FloatingActionButton(
                onClick = { viewModel.openColumn() },
                modifier = Modifier.align(Alignment.BottomEnd).padding(24.dp),
            ) {
                Text(text = "+", style = MaterialTheme.typography.headlineSmall)
            }
        }
    }
}

/** Along-space translation, before the axis turns it into a screen rectangle. */
private fun Rect.translatedAlong(delta: Double) = copy(x = x + delta)

@Composable
private fun ColumnWindow(
    tabId: UUID,
    frame: Rect,
    title: String,
    url: String?,
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
                    tabId = tabId,
                    url = url,
                    profileStoreName = profileStoreName,
                    onPageStarted = onPageStarted,
                    onTitleChanged = onTitleChanged,
                )
            }
        }

        ColumnHandle(
            title = title,
            url = url,
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

@Composable
private fun StartPage() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = stringResource(R.string.address_hint),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
