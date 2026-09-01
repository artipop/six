import Foundation
import GRDB
import Testing

@testable import SixCore

/// The profiles table: the identity `visits`, `bookmarks` and every cookie jar are keyed by.
///
/// It is here because of what its absence cost. The profiles used to live only in `state.json`, so a
/// snapshot that would not decode started the browser with fresh profiles and fresh
/// `WKWebsiteDataStore` identifiers — every login in every profile gone in one launch, and the site
/// data on disk orphaned rather than deleted. What these tests hold down is the part that makes that
/// impossible: the identifiers survive a rewrite, and the table cannot be emptied by asking.
@MainActor
struct ProfileStoreTests {
    /// A database with the profiles table and nothing else. Deliberately not `AppDatabase.open()`,
    /// which resolves a real path under `AppSupport`: a test must not reach the file a person's
    /// browser is using.
    private func store() throws -> (ProfileStore, any DatabaseWriter) {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE "profiles" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "name" TEXT NOT NULL DEFAULT '',
                  "colorHex" TEXT NOT NULL DEFAULT '',
                  "ord" INTEGER NOT NULL DEFAULT 0
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE "profile_storage" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "dataStoreID" TEXT NOT NULL,
                  "workingDirectoryPath" TEXT
                ) STRICT
                """)
        }
        return (ProfileStore(database: queue), queue)
    }

    private func record(_ name: String) -> ProfileRecord {
        ProfileRecord(id: UUID(), name: name, colorHex: "#5B8DEF", dataStoreID: UUID())
    }

    @Test func theDataStoreIdentifierSurvivesEveryRewrite() throws {
        let (profiles, database) = try store()
        let personal = record("Personal")
        profiles.save([personal, record("Work")])

        // A rename is a whole-list write, like every other edit. The identifier behind it — the
        // folder holding the cookies — is not the app's to change.
        var renamed = personal
        renamed.name = "Mine"
        profiles.save([renamed])

        let rows = ProfileStore(database: database).all()
        #expect(rows.map(\.name) == ["Mine"])
        #expect(rows.first?.dataStoreID == personal.dataStoreID)
    }

    @Test func theOrderIsTheOrderTheyWereGivenIn() throws {
        let (profiles, database) = try store()
        let (first, second, third) = (record("a"), record("b"), record("c"))
        profiles.save([first, second, third])
        profiles.save([third, first, second])

        #expect(ProfileStore(database: database).all().map(\.id) == [third.id, first.id, second.id])
    }

    /// The point of the split: the syncable half carries no address on this machine, and a profile
    /// that turns up without an address — which is the shape one arriving from another Mac would
    /// have — is given one here and now rather than a fresh one on every launch.
    @Test func whatTravelsAndWhatStays() throws {
        let (profiles, database) = try store()
        let personal = record("Personal")
        profiles.save([personal])

        let columns = try database.read { db in
            try String.fetchAll(db, sql: #"SELECT name FROM pragma_table_info('profiles')"#)
        }
        #expect(!columns.contains("dataStoreID"))
        #expect(!columns.contains("workingDirectoryPath"))

        // A row in `profiles` with nothing beside it in `profile_storage`.
        try database.write { db in try db.execute(sql: #"DELETE FROM "profile_storage""#) }
        let minted = ProfileStore(database: database).all()
        #expect(minted.count == 1)
        #expect(minted[0].dataStoreID != personal.dataStoreID)
        // And written down, so the next launch reads back the same one.
        #expect(ProfileStore(database: database).all().map(\.dataStoreID) == minted.map(\.dataStoreID))
    }

    @Test func anEmptyListIsRefusedRatherThanObeyed() throws {
        let (profiles, database) = try store()
        profiles.save([record("Personal")])
        profiles.save([])

        // A stale row costs a line in the profile bar. An emptied table costs every login there is.
        #expect(ProfileStore(database: database).all().count == 1)
    }
}
