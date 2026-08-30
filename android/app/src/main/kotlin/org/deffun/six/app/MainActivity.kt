package org.deffun.six.app

import android.content.ComponentCallbacks2
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {

    private val viewModel: SixViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { SixApp(onExit = { finish() }) }
    }

    /**
     * The system asking for memory back, which for a browser is a real event rather than a hint: a
     * strip of pages is exactly the kind of thing it is asking about.
     *
     * `TRIM_MEMORY_BACKGROUND` and above mean the process is a candidate for being killed. The strip
     * answers by keeping only the window being read; everything else keeps its address, its history
     * and its place, and is built again on the way back.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        viewModel.onMemoryPressure(level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND)
    }
}
