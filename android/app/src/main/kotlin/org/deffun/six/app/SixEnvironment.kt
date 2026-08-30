package org.deffun.six.app

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import java.io.File
import org.deffun.six.core.AppDatabase
import org.deffun.six.core.FileSnapshotStore
import org.deffun.six.core.HistoryStore
import org.deffun.six.core.SettingsStore

/**
 * Where six keeps its things on this platform, and the stores opened over them.
 *
 * The Mac puts these in `Application Support/org.deffun.six/` and Linux in `~/.local/share/six/`.
 * Android's equivalent is the app's own files directory: private, backed up with the app, and gone
 * when it is uninstalled. The *names* inside it are the same ones, because a file that travels
 * between platforms should be recognisable when it arrives.
 */
class SixEnvironment(private val context: Context) {

    val root: File = context.filesDir

    val snapshotFile: File = File(root, "state.json")

    /**
     * Opened lazily, and every caller reaches it from a background dispatcher.
     *
     * `AppDatabase.open` creates the file and runs migrations; doing that in a view model's field
     * initialiser puts it on the main thread at launch, which is disk I/O between the process
     * starting and the first frame. Nothing here forces it — the first touch does, and every one of
     * those is inside a coroutine on IO.
     */
    val database: AppDatabase by lazy {
        AppDatabase.open(File(root, AppDatabase.FILE_NAME)).also { isDatabaseOpen = true }
    }

    /** True once something has actually opened it, so closing does not open it in order to close. */
    private var isDatabaseOpen = false

    val snapshots = FileSnapshotStore(snapshotFile)
    val history: HistoryStore by lazy { HistoryStore(database) }
    val settings: SettingsStore by lazy { SettingsStore(database) }

    /** Whether the *app* has been allowed a device. The gate in front of the site's own answer. */
    fun hasSystemPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** One folder per profile, holding its bookmarks — phase two, but the layout is fixed now. */
    fun profileDirectory(name: String): File = File(File(root, "Profiles"), name)

    fun close() {
        if (isDatabaseOpen) database.close()
    }
}
