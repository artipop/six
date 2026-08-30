package org.deffun.six.app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import org.deffun.six.R

/**
 * The phone's whole window: the strip, and the little chrome a phone can spare for it.
 *
 * The same shape as the iPhone's `PhoneContentView` — the strip filling everything, one bar at the
 * bottom, and everything that is a sheet there is a sheet here.
 */
@Composable
fun PhoneContent(
    viewModel: SixViewModel = viewModel(),
    onExit: () -> Unit = {},
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var showHistory by remember { mutableStateOf(false) }
    var showPermissions by remember { mutableStateOf(false) }
    var confirmClearHistory by remember { mutableStateOf(false) }

    val focused = state.layout.focusedTabId?.let { state.tabs[it] }

    Column(modifier = Modifier.fillMaxSize()) {
        StripScreen(
            viewModel = viewModel,
            onExit = onExit,
            modifier = Modifier.weight(1f),
        )
        PhoneToolbar(
            canGoBack = focused?.canGoBack == true,
            canGoForward = focused?.canGoForward == true,
            isOverview = state.layout.isOverview,
            onBack = viewModel::goBack,
            onForward = viewModel::goForward,
            onNewWindow = { viewModel.openColumn() },
            onNewPrivateWindow = { viewModel.newPrivateWindow() },
            isPrivateOpen = state.profiles.any { it.isPrivate },
            onClosePrivate = viewModel::closePrivateBrowsing,
            onToggleOverview = viewModel::toggleOverview,
            onShowHistory = { showHistory = true },
            onShowPermissions = { showPermissions = true },
            onClearHistory = { confirmClearHistory = true },
        )
    }

    if (showHistory) {
        HistorySheet(
            viewModel = viewModel,
            onOpen = { url ->
                showHistory = false
                viewModel.openColumn(url)
            },
            onDismiss = { showHistory = false },
        )
    }

    // The app's own permission, asked for only once a site has been allowed - and asked for by the
    // system, which is the one thing here that is not six's to decide.
    val systemPermissions = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { result ->
        viewModel.onSystemPermissionsResult(result.values.all { it })
    }
    LaunchedEffect(state.pendingSystemPermissions) {
        val wanted = state.pendingSystemPermissions
        if (wanted.isNotEmpty()) systemPermissions.launch(wanted.toTypedArray())
    }

    if (showPermissions) {
        // Read through `permissionRevision` so answering or forgetting redraws the list.
        val sites = remember(state.permissionRevision) { viewModel.permissionSites() }
        PermissionsSheet(
            sites = sites,
            decisionsFor = viewModel::permissionDecisions,
            profileNameFor = { site ->
                state.profiles.firstOrNull { it.id == site.profileId }?.name.orEmpty()
            },
            onForget = viewModel::forgetPermissions,
            onDismiss = { showPermissions = false },
        )
    }

    PageDialogHost(request = state.pageDialog, onAnswer = viewModel::answerPageDialog)

    if (confirmClearHistory) {
        val profileName = state.profiles
            .firstOrNull { it.id == state.layout.activeProfileId }?.name.orEmpty()

        // The Mac's question, with the Mac's two answers: the profile's history, or its history and
        // the site data behind it. Clearing one profile never touches another.
        AlertDialog(
            onDismissRequest = { confirmClearHistory = false },
            title = { Text(stringResource(R.string.clear_history_title, profileName)) },
            text = { Text(stringResource(R.string.clear_history_message)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmClearHistory = false
                    viewModel.clearHistory(includingSiteData = true)
                }) { Text(stringResource(R.string.clear_history_and_site_data)) }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { confirmClearHistory = false }) {
                        Text(stringResource(R.string.cancel))
                    }
                    TextButton(onClick = {
                        confirmClearHistory = false
                        viewModel.clearHistory(includingSiteData = false)
                    }) { Text(stringResource(R.string.clear_history_only)) }
                }
            },
        )
    }
}
