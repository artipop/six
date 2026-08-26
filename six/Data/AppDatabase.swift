import Foundation
import GRDB
import SQLiteData
import SQLiteVecData

/// The one SQLite file: `~/Library/Application Support/six/six.sqlite`. Opened once at launch,
/// migrated forward only. Tables follow SQLiteData's CloudKit rules from day one (see
/// docs/storage.md): UUID text primary keys, no `UNIQUE` on other columns, columns are only ever
/// added — so switching the `SyncEngine` on later is configuration, not a migration.
nonisolated enum AppDatabase {
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "six/six.sqlite")
    }

    static func open() throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // sqlite-vec goes into every connection by hand (`sqlite3_vec_init` on the handle): the Apple
        // SQLite has extension loading compiled out, so `sqlite3_auto_extension` is refused there.
        var configuration = GRDB.Configuration()
        configuration.prepareDatabase { db in try db.loadSQLiteVecExtension() }
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
        try migrator.migrate(database)
        return database
    }
}
