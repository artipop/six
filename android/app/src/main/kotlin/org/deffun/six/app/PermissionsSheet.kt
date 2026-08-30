package org.deffun.six.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.deffun.six.R
import org.deffun.six.core.PermissionSite
import org.deffun.six.core.SitePermission

/**
 * Every site that has been answered, and the way to take an answer back.
 *
 * A site forgotten here asks again the next time it needs the device, which is the undo the whole
 * design exists to make possible — the engine's own prompt has nowhere to put one.
 *
 * The same origin can appear twice, answered differently in two profiles, so a row is the pair and
 * never the origin alone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PermissionsSheet(
    sites: List<PermissionSite>,
    decisionsFor: (PermissionSite) -> Map<SitePermission, Boolean>,
    profileNameFor: (PermissionSite) -> String,
    onForget: (PermissionSite) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            text = stringResource(R.string.site_permissions),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
        )

        if (sites.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp),
                contentAlignment = Alignment.Center,
            ) { Text(stringResource(R.string.site_permissions_empty)) }
        } else {
            LazyColumn {
                items(sites, key = { "${it.profileId}${it.origin}" }) { site ->
                    SiteRow(
                        site = site,
                        decisions = decisionsFor(site),
                        profileName = profileNameFor(site),
                        onForget = { onForget(site) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun SiteRow(
    site: PermissionSite,
    decisions: Map<SitePermission, Boolean>,
    profileName: String,
    onForget: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = site.origin,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = summary(decisions, profileName),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(onClick = onForget) { Text(stringResource(R.string.forget_site)) }
    }
}

@Composable
private fun summary(decisions: Map<SitePermission, Boolean>, profileName: String): String {
    val allowed = decisions.filterValues { it }.keys.toList()
    val denied = decisions.filterValues { !it }.keys.toList()
    val parts = buildList {
        if (allowed.isNotEmpty()) add(stringResource(R.string.allowed) + ": " + describe(allowed))
        if (denied.isNotEmpty()) add(stringResource(R.string.denied) + ": " + describe(denied))
        if (profileName.isNotEmpty()) add(profileName)
    }
    return parts.joinToString(" · ")
}
