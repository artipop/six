import Foundation
import GRDB
import Testing

@testable import SixCore

/// The settings table, which is where six keeps everything that is not a record: the search engine,
/// the live-page budget, the strip's shape, what sites were allowed the camera.
///
/// One test, and it is here because the thing it checks was broken. Writes went in as a plain
/// `INSERT`, so a key could be written once and never changed — the second write failed on the
/// primary key, the error was caught and printed, and the in-memory cache took the new value anyway.
/// Nothing looked wrong until the next launch read the old value back. A store that quietly loses
/// the *second* of two writes is exactly the kind of thing worth a test that fails loudly.
@MainActor
struct SettingsStoreTests {
    /// A database with the settings table and nothing else. Deliberately not `AppDatabase.open()`:
    /// that resolves a real path under `AppSupport`, and a test must not be able to touch the file a
    /// person's browser is using.
    private func store() throws -> (SettingsStore, any DatabaseWriter) {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE "settings" (
                  "key" TEXT PRIMARY KEY NOT NULL,
                  "value" TEXT NOT NULL
                )
                """)
        }
        return (SettingsStore(database: queue), queue)
    }

    @Test func aSecondWriteReachesTheDatabase() throws {
        let (settings, database) = try store()
        settings[.stripState] = "first"
        settings[.stripState] = "second"

        // Read through a *new* store, because the one that wrote it would answer from its cache —
        // which is what hid the bug.
        #expect(SettingsStore(database: database)[.stripState] == "second")
    }

    @Test func aChangedKeyIsUpdatedRatherThanDuplicated() throws {
        let (settings, database) = try store()
        settings[.defaultProfile] = "a"
        settings[.defaultProfile] = "b"
        settings[.defaultProfile] = "c"

        let rows = try database.read { db in
            try Int.fetchOne(db, sql: #"SELECT count(*) FROM "settings" WHERE "key" = ?"#,
                             arguments: [SettingsStore.Key.defaultProfile.rawValue])
        }
        #expect(rows == 1)
    }

    /// Clearing a key removes the row, so the next launch falls back to the default rather than
    /// reading an empty string as an answer.
    @Test func clearingRemovesTheRow() throws {
        let (settings, database) = try store()
        settings[.stripState] = "something"
        settings[.stripState] = nil

        #expect(SettingsStore(database: database)[.stripState] == nil)
    }
}
