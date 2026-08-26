import Foundation
import SQLiteData

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
        let database = try defaultDatabase(path: url.path)
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
        try migrator.migrate(database)
        return database
    }
}
