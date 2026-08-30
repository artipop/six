package org.deffun.six.app

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
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
                                onDrag(along, across)
                            }
                        }
                }
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (isEditing) {
            AddressField(initial = url.orEmpty(), onSubmit = onSubmit, onCancel = onCancel)
        } else {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = title.ifEmpty { url ?: stringResource(R.string.start_page_title) },
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (isFocused) {
                    // The Mac puts the × on the window's own corner and waits for the pointer.
                    // A finger has no hover, so it lives in the chrome that is already there.
                    Text(
                        text = "×",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier
                            .padding(start = 12.dp)
                            .pointerInput(Unit) { detectTapGestures { onClose() } },
                    )
                }
            }
        }
    }
}

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
