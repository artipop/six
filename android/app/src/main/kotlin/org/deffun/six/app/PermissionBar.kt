package org.deffun.six.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.deffun.six.R
import org.deffun.six.core.SitePermission

/**
 * The question, in the window that asked it.
 *
 * The Mac puts this under the window's title bar rather than in a system dialog, and for the reason
 * that makes six answer these requests at all: a page left to the engine gets its answer from a
 * popover nobody wrote down, so the same site asks again on every load and there is nowhere to take
 * an answer back. A bar in the window is the price of the memory and the undo.
 *
 * One bar for everything asked at once — "camera and microphone" is one question and two answers.
 */
@Composable
fun PermissionBar(
    host: String,
    permissions: List<SitePermission>,
    onAnswer: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.secondaryContainer)
            .padding(start = 14.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = stringResource(R.string.permission_asks, host, describe(permissions)),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = { onAnswer(false) }) { Text(stringResource(R.string.deny)) }
        TextButton(onClick = { onAnswer(true) }) { Text(stringResource(R.string.allow)) }
    }
}

/**
 * "camera", "microphone", "camera and microphone".
 *
 * The names are lowercase because they are read inside a sentence, which is the same reason the
 * Mac's `SitePermission.label` is — and they are joined by a translated string rather than a comma,
 * because "and" is not punctuation in every language it will be read in.
 */
@Composable
fun describe(permissions: List<SitePermission>): String {
    val names = permissions.map { stringResource(it.labelId) }
    return when (names.size) {
        0 -> ""
        1 -> names.first()
        else -> names.reduce { joined, next -> stringResource(R.string.permission_and, joined, next) }
    }
}

val SitePermission.labelId: Int
    get() = when (this) {
        SitePermission.CAMERA -> R.string.permission_camera
        SitePermission.MICROPHONE -> R.string.permission_microphone
        SitePermission.MOTION -> R.string.permission_motion
    }
