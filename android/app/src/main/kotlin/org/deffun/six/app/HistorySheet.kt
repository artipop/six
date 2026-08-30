package org.deffun.six.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import org.deffun.six.R
import org.deffun.six.core.SearchEngine
import org.deffun.six.core.Visit

/**
 * The history of the profile on screen, newest first — the same rows the Mac wrote.
 *
 * A search results page is shown as its query rather than as its title, which is what
 * `Visit.displayTitle` does on the Mac and the reason `SearchEngine.search` came across into
 * `:core`: "плов рецепт · DuckDuckGo" reads as what you did, and the page's own title does not.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistorySheet(
    viewModel: SixViewModel,
    onOpen: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var visits by remember { mutableStateOf<List<Visit>?>(null) }

    LaunchedEffect(Unit) { visits = viewModel.historyEntries() }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        val entries = visits
        when {
            entries == null -> Box(
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                contentAlignment = Alignment.Center,
            ) { Text("…") }

            entries.isEmpty() -> Box(
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                contentAlignment = Alignment.Center,
            ) { Text(stringResource(R.string.history_empty)) }

            else -> LazyColumn {
                items(entries, key = { it.id }) { visit ->
                    VisitRow(visit, onOpen = { onOpen(visit.url) })
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun VisitRow(visit: Visit, onOpen: () -> Unit) {
    val search = SearchEngine.search(visit.url)
    val title = search?.second ?: visit.title.ifEmpty { visit.url }
    val detail = search?.let { "${it.first.title} Search" } ?: host(visit.url)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(horizontal = 20.dp, vertical = 12.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = "$detail · ${TIME.format(visit.visitedAt.atZone(ZoneId.systemDefault()))}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private val TIME: DateTimeFormatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)

private fun host(url: String): String =
    runCatching { java.net.URI(url).host }.getOrNull() ?: url
