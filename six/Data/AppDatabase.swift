import Foundation
import GRDB
import SQLiteData
#if canImport(Darwin) && canImport(SQLiteVecData)
// The app links sqlite-vec; `SixCore` deliberately does not, so on the Linux and Windows fronts
// loading the extension is the front's own first line (`Vectors.register()` in each `SixBrowser`).
// `canImport(Darwin)` and not `canImport(SQLiteVecData)` alone, and the difference is not
// decoration: those fronts *do* have the package in their graph, so `canImport` answers yes there
// while `SixCore` still has no dependency to import through, and the build stops on "missing
// required module 'CSQLiteVec'" three files away from anything that mentions vectors.
import SQLiteVecData
#endif

/// The one SQLite file: `~/Library/Application Support/org.deffun.six/six.sqlite`. Opened once at launch,
/// migrated forward only. Tables follow SQLiteData's CloudKit rules from day one (see
/// docs/storage.md): UUID text primary keys, no `UNIQUE` on other columns, columns are only ever
/// added — so switching the `SyncEngine` on later is configuration, not a migration.
nonisolated enum AppDatabase {
    static var url: URL {
        AppSupport.file("six.sqlite")
    }

    static func open() throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = GRDB.Configuration()
        #if canImport(Darwin) && canImport(SQLiteVecData)
        // sqlite-vec goes into every connection by hand (`sqlite3_vec_init` on the handle): the Apple
        // SQLite has extension loading compiled out, so `sqlite3_auto_extension` is refused there —
        // and, because it is compiled out, the redefinitions in `sqlite3ext.h` are too, which is
        // what makes a null API table harmless here and a crash everywhere else. The fronts that
        // link their own SQLite take the other branch, in their own `Vectors.register()`.
        configuration.prepareDatabase { db in try db.loadSQLiteVecExtension() }
        #endif
        let database = try defaultDatabase(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1 visits, settings") { db in
            try #sql("""
                CREATE TABLE "visits" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "profileID" TEXT NOT NULL,
                  "url" TEXT NOT NULL,
                  "title" TEXT NOT NULL DEFAULT '',
                  "visitedAt" TEXT NOT NULL
                ) STRICT
                """).execute(db)
            try #sql("""
                CREATE INDEX "visits_by_profile_time" ON "visits"("profileID", "visitedAt" DESC)
                """).execute(db)
            try #sql("""
                CREATE TABLE "settings" (
                  "key" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "value" TEXT NOT NULL
                ) STRICT
                """).execute(db)
        }
        migrator.registerMigration("v2 bookmarks") { db in
            try #sql("""
                CREATE TABLE "bookmarks" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "profileID" TEXT NOT NULL,
                  "url" TEXT NOT NULL,
                  "title" TEXT NOT NULL DEFAULT '',
                  "excerpt" TEXT NOT NULL DEFAULT '',
                  "siteName" TEXT NOT NULL DEFAULT '',
                  "imageURL" TEXT,
                  "fileName" TEXT NOT NULL DEFAULT '',
                  "language" TEXT NOT NULL DEFAULT '',
                  "characterCount" INTEGER NOT NULL DEFAULT 0,
                  "createdAt" TEXT NOT NULL,
                  "indexedAt" TEXT,
                  "embeddingModel" TEXT NOT NULL DEFAULT '',
                  "indexError" TEXT
                ) STRICT
                """).execute(db)
            try #sql("""
                CREATE INDEX "bookmarks_by_profile_time" ON "bookmarks"("profileID", "createdAt" DESC)
                """).execute(db)
            try #sql("""
                CREATE TABLE "bookmark_chunks" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "bookmarkID" TEXT NOT NULL,
                  "ord" INTEGER NOT NULL DEFAULT 0,
                  "text" TEXT NOT NULL
                ) STRICT
                """).execute(db)
            try #sql("""
                CREATE INDEX "bookmark_chunks_by_bookmark" ON "bookmark_chunks"("bookmarkID", "ord")
                """).execute(db)
            // The vector index: one unit-length float32 vector per chunk, scanned in Swift (see
            // `BookmarkStore.vectorSearch`). Local only, rebuildable from the chunks; a BLOB in its
            // own table, as SQLiteData's CloudKit rules want. The Apple SQLite refuses extensions —
            // `sqlite3_auto_extension` answers SQLITE_MISUSE — so sqlite-vec would need our own SQLite
            // build under GRDB; docs/bookmarks.md has the trade-off.
            try #sql("""
                CREATE TABLE "bookmark_vectors" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "chunkID" TEXT NOT NULL,
                  "bookmarkID" TEXT NOT NULL,
                  "profileID" TEXT NOT NULL,
                  "model" TEXT NOT NULL,
                  "embedding" BLOB NOT NULL
                ) STRICT
                """).execute(db)
            try #sql("""
                CREATE INDEX "bookmark_vectors_by_model_profile" ON "bookmark_vectors"("model", "profileID")
                """).execute(db)
        }
        migrator.registerMigration("v3 bookmark refresh") { db in
            try #sql("""
                ALTER TABLE "bookmarks" ADD COLUMN "refreshedAt" TEXT
                """).execute(db)
            try #sql("""
                ALTER TABLE "bookmarks" ADD COLUMN "contentHash" TEXT NOT NULL DEFAULT ''
                """).execute(db)
            try #sql("""
                ALTER TABLE "bookmarks" ADD COLUMN "refreshError" TEXT
                """).execute(db)
        }
        migrator.registerMigration("v4 vectors in vec0") { db in
            // The float32-BLOB table scanned in Swift gave way to sqlite-vec's `vec0` tables, which
            // `BookmarkStore` creates per vector dimension; the index is rebuilt from the chunks.
            try #sql("""
                DROP TABLE IF EXISTS "bookmark_vectors"
                """).execute(db)
        }
        migrator.registerMigration("v5 profiles") { db in
            // The profiles come off `state.json` and into the file that already holds everything
            // keyed by them (`visits`, `bookmarks`, `bookmark_vectors`). While the identity lived
            // only in the snapshot, one file that would not decode logged the user out of every
            // profile at once — see `ProfileStore` for the whole of it.
            //
            // Two tables, not one, and the reason is the sync engine that isn't written yet:
            // `SyncEngine(for:tables:privateTables:)` names tables and there is no filter below one.
            // So who the profile *is* — a name, a colour, an order, under an id two Macs can agree
            // on — is a table that may be named, and where this Mac keeps the profile's things is a
            // table that never is. `dataStoreID` addresses a folder under
            // `~/Library/WebKit/<bundle identifier>` and `workingDirectoryPath` a folder on this
            // disk; neither means anything anywhere else. See docs/sync.md.
            try #sql("""
                CREATE TABLE "profiles" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "name" TEXT NOT NULL DEFAULT '',
                  "colorHex" TEXT NOT NULL DEFAULT '',
                  "ord" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """).execute(db)
            try #sql("""
                CREATE TABLE "profile_storage" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "dataStoreID" TEXT NOT NULL,
                  "workingDirectoryPath" TEXT
                ) STRICT
                """).execute(db)
        }
        try migrator.migrate(database)
        return database
    }
}
