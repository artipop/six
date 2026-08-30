package org.deffun.six.app

import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import org.deffun.six.R
import org.deffun.six.core.StripAxis

/** The handle above each window: the title, the address field, and the strip's only drag surface. */
val HandleHeight = 36.dp

/**
 * A phone has no ⌘L and no room for a bar of its own, so the address is typed where the title is.
 *
 * Three states, and the difference between the last two is the whole design: a window that is not
 * focused only takes focus when tapped, so walking the strip never opens the keyboard; the focused
 * one turns into a field.
 */
@Composable
fun ColumnHandle(
    title: String,
    url: String?,
    accent: Color,
    isLoading: Boolean,
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
) {
    val density = LocalDensity.current

    // Focus moving away closes the field, the way it does on the phone: otherwise the keyboard
    // stays up for a window that is no longer the one being read.
    LaunchedEffect(isFocused) { if (!isFocused && isEditing) onCancel() }

    val background =
        if (isFocused) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.surface

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(HandleHeight)
            .background(background)
            .then(
                // While the field is open the handle is a text field and nothing else: a drag here
                // would move the strip out from under the keyboard.
                if (isEditing) {
                    Modifier
                } else {
                    Modifier
                        .pointerInput(isFocused) { detectTapGestures { onTap() } }
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
                                // The dominant direction decides and the other band is zeroed while
                                // the drag is still happening — the iPhone's rule. A hand that is
                                // not quite straight walks the strip rather than doing a little of
                                // both, and the strip never drifts diagonally under the finger.
                                if (abs(along) > abs(across)) {
                                    onDrag(along, 0.0)
                                } else {
                                    onDrag(0.0, across)
                                }
                            }
                        }
                }
            ),
        contentAlignment = Alignment.Center,
    ) {
        // One row, always: the dot, the title *or* the field, and the ×. The iPhone's handle keeps
        // all three at once, which is what makes the × the way out of the address field as well as
        // the way to close a window.
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(accent.copy(alpha = if (isLoading) 0.4f else 1f)),
            )

            Box(modifier = Modifier.weight(1f).padding(horizontal = 10.dp)) {
                if (isEditing) {
                    AddressField(initial = url.orEmpty(), onSubmit = onSubmit, onCancel = onCancel)
                } else {
                    Text(
                        text = title.ifEmpty { url?.let(::host) ?: stringResource(R.string.start_page_title) },
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            // As on the phone, it backs out of the address field before it closes anything.
            Text(
                text = "×",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(36.dp)
                    .wrapContentSize(Alignment.Center)
                    .pointerInput(isEditing) {
                        detectTapGestures { if (isEditing) onCancel() else onClose() }
                    },
            )
        }
    }
}

private fun host(url: String): String =
    runCatching { java.net.URI(url).host }.getOrNull() ?: url

@Composable
private fun AddressField(
    initial: String,
    onSubmit: (String) -> Unit,
    onCancel: () -> Unit,
) {
    // Unkeyed on purpose. This composable only exists while the field is open, so it starts from
    // the current address every time it opens — and keying it on `initial` would do the opposite of
    // what it looks like, throwing away what is being typed the moment the page underneath
    // navigates and changes the address.
    var text by remember { mutableStateOf(initial) }
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    BasicTextField(
        value = text,
        onValueChange = { text = it },
        singleLine = true,
        textStyle = LocalTextStyle.current.copy(color = MaterialTheme.colorScheme.onSurface),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
        keyboardActions = KeyboardActions(
            onGo = {
                keyboard?.hide()
                if (text.isBlank()) onCancel() else onSubmit(text)
            },
        ),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .focusRequester(focusRequester),
    )
}
