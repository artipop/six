package org.deffun.six.app

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import org.deffun.six.R
import org.deffun.six.core.PageDialogAnswer
import org.deffun.six.core.PageDialogKind
import org.deffun.six.core.PageDialogRequest

/**
 * The dialogs a page puts up, over the whole window: one at a time, each saying which site it came
 * from.
 *
 * Every path out of here calls [onAnswer] exactly once for this request, including dismissal. That
 * is not tidiness: a `JsResult` left hanging suspends that page's JavaScript for good, and a file
 * chooser whose callback never lands makes that input permanently dead with no error anywhere.
 */
@Composable
fun PageDialogHost(
    request: PageDialogRequest?,
    onAnswer: (java.util.UUID, PageDialogAnswer) -> Unit,
) {
    if (request == null) return

    val answer = { value: PageDialogAnswer -> onAnswer(request.id, value) }
    val site = request.host.ifEmpty { stringResource(R.string.this_page) }

    when (val kind = request.kind) {
        is PageDialogKind.File -> FileChooser(requestId = request.id, kind = kind, onAnswer = answer)

        is PageDialogKind.Prompt -> {
            // Keyed on the request, so a second page's prompt does not open holding what was typed
            // into the first.
            var text by remember(request.id) { mutableStateOf(kind.defaultText) }
            AlertDialog(
                onDismissRequest = { answer(PageDialogAnswer.Cancel) },
                title = { Text(stringResource(R.string.page_says, site)) },
                text = {
                    Column {
                        if (request.message.isNotEmpty()) Text(request.message)
                        BasicTextField(
                            value = text,
                            onValueChange = { text = it },
                            singleLine = true,
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    }
                },
                confirmButton = {
                    TextButton(onClick = { answer(PageDialogAnswer.Ok(text)) }) {
                        Text(stringResource(android.R.string.ok))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { answer(PageDialogAnswer.Cancel) }) {
                        Text(stringResource(R.string.cancel))
                    }
                },
            )
        }

        else -> AlertDialog(
            onDismissRequest = { answer(PageDialogAnswer.Cancel) },
            title = { Text(stringResource(R.string.page_says, site)) },
            text = { Text(request.message) },
            confirmButton = {
                TextButton(onClick = { answer(PageDialogAnswer.Ok()) }) {
                    Text(stringResource(android.R.string.ok))
                }
            },
            // `alert()` has one button by definition: there is nothing to decline.
            dismissButton = if (kind is PageDialogKind.Confirm) {
                {
                    TextButton(onClick = { answer(PageDialogAnswer.Cancel) }) {
                        Text(stringResource(R.string.cancel))
                    }
                }
            } else {
                null
            },
        )
    }
}

/**
 * `<input type="file">`, answered by the system picker.
 *
 * The Mac has to copy what the picker returns into its own temporary folder, because a
 * security-scoped URL stops being readable the moment the scope closes and WebKit reads it later. On
 * Android the grant belongs to this process for as long as the activity lives and the WebView is in
 * that process, so the `content://` URI goes straight across.
 */
@Composable
private fun FileChooser(
    requestId: java.util.UUID,
    kind: PageDialogKind.File,
    onAnswer: (PageDialogAnswer) -> Unit,
) {
    // Anything, unless the input said otherwise. `*/*` rather than an empty array: the picker shows
    // nothing at all for an empty one.
    val types = remember(kind) {
        // `accept` is not always MIME: `accept=".pdf"` is a perfectly ordinary input and an
        // extension is not a type the picker understands. Anything without a slash is dropped, and
        // dropping everything means anything — `*/*` rather than an empty array, for which the
        // picker shows nothing at all.
        kind.acceptTypes
            .filter { it.contains('/') }
            .ifEmpty { listOf("*/*") }
            .toTypedArray()
    }

    val multiple = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        onAnswer(PageDialogAnswer.Files(uris.map { it.toString() }))
    }
    val single = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        // A cancelled picker returns null, and that has to reach the page as a cancel rather than as
        // silence.
        onAnswer(
            if (uri == null) PageDialogAnswer.Cancel
            else PageDialogAnswer.Files(listOf(uri.toString())),
        )
    }

    // Keyed on the request and not on the kind. Two identical file inputs in a row produce two
    // equal `PageDialogKind.File` values, and keying on those would skip the second launch — leaving
    // a callback that never lands, which is the one failure that kills an input permanently.
    LaunchedEffect(requestId) {
        if (kind.allowsMultiple) multiple.launch(types) else single.launch(types)
    }
}
