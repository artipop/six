package org.deffun.six.app

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun SixApp(onExit: () -> Unit = {}) {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            PhoneContent(onExit = onExit)
        }
    }
}
