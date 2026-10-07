import Foundation
import GRDB
import Testing

@testable import SavoiaCore

/// The settings table, which is where Savoia keeps everything that is not a record: the search engine,
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
    private func store() throws -> (ConfigurationStore, any DatabaseWriter) {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE "settings" (
                  "key" TEXT PRIMARY KEY NOT NULL,
                  "value" TEXT NOT NULL
                )
                """)
        }
        return (ConfigurationStore(database: queue), queue)
    }

    @Test func aSecondWriteReachesTheDatabase() throws {
        let (settings, database) = try store()
        settings[.pageName] = "first"
        settings[.pageName] = "second"

        // Read through a *new* store, because the one that wrote it would answer from its cache —
        // which is what hid the bug.
        #expect(ConfigurationStore(database: database)[.pageName] == "second")
    }

    @Test func aChangedKeyIsUpdatedRatherThanDuplicated() throws {
        let (settings, database) = try store()
        settings[.defaultProfile] = "a"
        settings[.defaultProfile] = "b"
        settings[.defaultProfile] = "c"

        let rows = try database.read { db in
            try Int.fetchOne(db, sql: #"SELECT count(*) FROM "settings" WHERE "key" = ?"#,
                             arguments: [ConfigurationStore.Key.defaultProfile.rawValue])
        }
        #expect(rows == 1)
    }

    /// Clearing a key removes the row, so the next launch falls back to the default rather than
    /// reading an empty string as an answer.
    @Test func clearingRemovesTheRow() throws {
        let (settings, database) = try store()
        settings[.pageName] = "something"
        settings[.pageName] = nil

        #expect(ConfigurationStore(database: database)[.pageName] == nil)
    }

    @Test func anAnswerThisBuildCannotReadCostsOnlyItself() throws {
        let (settings, _) = try store()
        let profile = UUID()
        settings[.sitePermissions] = """
            [{"profileID":"\(profile)","origin":"https://a.example","permission":"camera","isAllowed":true},
             {"profileID":"\(profile)","origin":"https://a.example","permission":"something-newer","isAllowed":true},
             {"profileID":"\(profile)","origin":"https://b.example","permission":"location","isAllowed":false}]
            """

        #expect(settings.sitePermissions.map(\.permission) == [.camera, .location])
    }
}
