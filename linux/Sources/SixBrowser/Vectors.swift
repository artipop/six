import Foundation
import GRDB

internal import SQLiteVecData
@testable internal import SixCore

/// sqlite-vec, into every connection this process opens.
///
/// One call, and where it goes is the whole of the file. sqlite-vec is a SQLite extension: the
/// `vec0` virtual table and the KNN behind it do not exist in a connection that has not loaded it,
/// and `AppDatabase` opens one as soon as it is asked. So this runs before the first
/// `AppDatabase.open()` and not from inside it — the root package deliberately does not depend on
/// sqlite-vec, because naming it there puts `CSQLiteVec` in front of Adwaita's own SQLite and Clang
/// will not hold two definitions of `sqlite3_api_routines` in one compilation unit (7806432). This
/// target is the one that has no Adwaita in it, so this is where the dependency can live, and
/// `internal import` is what keeps it from reaching `SixUI` the way `SixCore` already doesn't.
///
/// **`sqlite3_auto_extension`, not `prepareDatabase`, and that is not a preference.** The Mac loads
/// sqlite-vec into each connection by hand because Apple's SQLite has extension loading compiled
/// out and refuses the process-global call. Here it is the other way round: the system SQLite has
/// loading left in, so `sqlite-vec.c` compiles as a *loadable* extension and every SQLite call
/// inside it goes through the `sqlite3_api_routines` table it is handed at init.
/// `sqlite3_vec_init(db, nil, nil)` — which is what `Database.loadSQLiteVecExtension()` does — hands
/// it a null table, and the segfault is on the first call through it, inside the extension.
/// `sqlite3_auto_extension` is the entry point that passes a real one.
enum Vectors {
    private static var registered = false

    /// Registers sqlite-vec for every connection opened after this returns. Idempotent, and safe to
    /// call before anything else — it touches no database, only the SQLite library.
    ///
    /// A failure is reported and stepped over, the way this front already treats a database that
    /// will not open: what is lost is the vector index, and a browser whose bookmarks fall back to
    /// matching titles is still a browser.
    static func register() {
        guard !registered else { return }
        do {
            try registerSQLiteVecAutoExtension()
            registered = true
        } catch {
            Log.error(.bookmarks, "sqlite-vec unavailable: \(error)")
        }
    }
}

extension Vectors {
    /// `SIX_VEC_SELFTEST=1`: say whether this build actually has a vector index, and stop.
    ///
    /// Beside the database rather than in `main`, because the interesting failure is the one where
    /// registration succeeded and the connection still has no `vec0` in it — which only a real
    /// connection can be asked about. `VectorIndex.selfTest` is the shared half, so the Mac, Linux
    /// and Windows all answer the same question in the same words.
    static func selfTestIfAsked(_ database: any DatabaseWriter) {
        guard ProcessInfo.processInfo.environment["SIX_VEC_SELFTEST"] == "1" else { return }
        Log.info(.bookmarks, "vector self-test\n" + VectorIndex.selfTest(in: database))
    }
}
