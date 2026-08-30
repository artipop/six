package org.deffun.six.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.deffun.six.R

/**
 * One bar, at the bottom, where a thumb is.
 *
 * The shape is the iPhone's `PhoneToolbar` and deliberately so: back, forward, a new window, the
 * overview, and everything else behind `⋯`. The Mac puts these in a menu bar and a top bar; a phone
 * has neither to give away.
 *
 * The menu is shorter than the iPhone's, and shorter honestly: filter lists and extensions are out
 * of scope outright (docs/android.md), and a menu item that opens an empty sheet is worse than one
 * that is not there.
 */
@Composable
fun PhoneToolbar(
    canGoBack: Boolean,
    canGoForward: Boolean,
    isOverview: Boolean,
    onBack: () -> Unit,
    onForward: () -> Unit,
    onNewWindow: () -> Unit,
    onNewPrivateWindow: () -> Unit,
    isPrivateOpen: Boolean,
    onClosePrivate: () -> Unit,
    onToggleOverview: () -> Unit,
    onShowHistory: () -> Unit,
    onShowPermissions: () -> Unit,
    onShowBookmarks: () -> Unit,
    canAddBookmark: Boolean,
    onAddBookmark: () -> Unit,
    onClearHistory: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember { mutableStateOf(false) }

    Surface(
        modifier = modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlyphButton("‹", R.string.back, enabled = canGoBack, onClick = onBack)
            GlyphButton("›", R.string.forward, enabled = canGoForward, onClick = onForward)

            Spacer(modifier = Modifier.weight(1f))

            GlyphButton("+", R.string.new_window, onClick = onNewWindow)
            GlyphButton(if (isOverview) "▣" else "▢", R.string.overview, onClick = onToggleOverview)

            Box {
                GlyphButton("⋯", R.string.more, onClick = { menuOpen = true })
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.new_window_in_strip)) },
                        onClick = {
                            menuOpen = false
                            onNewWindow()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.new_private_window)) },
                        onClick = {
                            menuOpen = false
                            onNewPrivateWindow()
                        },
                    )
                    if (isPrivateOpen) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.close_private_browsing)) },
                            onClick = {
                                menuOpen = false
                                onClosePrivate()
                            },
                        )
                    }
                    HorizontalDivider()
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.bookmarks_ellipsis)) },
                        onClick = {
                            menuOpen = false
                            onShowBookmarks()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.history_ellipsis)) },
                        onClick = {
                            menuOpen = false
                            onShowHistory()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.site_permissions_ellipsis)) },
                        onClick = {
                            menuOpen = false
                            onShowPermissions()
                        },
                    )
                    if (canAddBookmark) {
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.add_bookmark)) },
                            onClick = {
                                menuOpen = false
                                onAddBookmark()
                            },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.clear_history_ellipsis)) },
                        onClick = {
                            menuOpen = false
                            onClearHistory()
                        },
                    )
                }
            }
        }
    }
}

/**
 * A button drawn as a character rather than an icon.
 *
 * The iPhone's toolbar is SF Symbols; these are a placeholder for real icons and not a style. The
 * label a screen reader reads is a translated string either way, which is the part that has to be
 * right now rather than later.
 */
@Composable
private fun GlyphButton(
    glyph: String,
    descriptionId: Int,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val description = stringResource(descriptionId)
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.semantics { contentDescription = description },
    ) {
        Text(
            text = glyph,
            style = MaterialTheme.typography.titleLarge,
            color = if (enabled) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
            },
        )
    }
}
