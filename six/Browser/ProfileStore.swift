import Foundation
import SQLiteData

/// A profile, whole: what it is called and where its cookies are.
///
/// It is one value here and two rows in the database, because the two halves belong to different
/// places. The name, the colour and the order are the profile — the same profile on any Mac the
/// person owns. `dataStoreID` and `workingDirectoryPath` are addresses on *this* machine: a folder
/// under `~/Library/WebKit/<bundle identifier>` and a folder the agents work in. Sending those to
/// another Mac would name nothing there.
///
/// Callers never see the seam. `ProfileStore` splits on the way in and joins on the way out.
nonisolated struct ProfileRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    var name = ""
    var colorHex = ""
    /// The persistent `WKWebsiteDataStore` behind the profile: its cookies, its storage, its logins.
    var dataStoreID: UUID
    /// Where agents work for this profile when the user picked a folder; nil is the scratchpad.
    var workingDirectoryPath: String?
    /// Where the profile sits in the bar.
    var ord = 0
}

/// The half that could travel: who the profile is.
///
/// `visits`, `bookmarks` and `bookmark_vectors` are all keyed by this id, and until it had a table
/// the row it names lived only in `state.json` — so one snapshot that would not decode started the
/// browser with `Profile.defaults`, minted fresh data stores, and the autosave wrote them over the
/// only copy of the old ones a second later. Every login in every profile, gone; the site data
/// orphaned on disk rather than deleted. The identity belongs in the file the rest of it is in.
///
/// This table follows SQLiteData's CloudKit rules and is the one that may one day be named to a
/// `SyncEngine`, so that two Macs agree on whose history is whose ([sync.md](../../docs/sync.md)).
///
/// Nothing seeds it from the snapshot. An empty table is a new browser and is read as one — a
/// migration that runs on exactly one launch is a branch nobody can tell is dead afterwards, and it
/// would have bought a single relaunch's worth of cookies.
@Table("profiles")
nonisolated struct ProfileIdentity: Identifiable, Sendable, Hashable {
    let id: UUID
    var name = ""
    var colorHex = ""
    var ord = 0
}

/// The half that stays: where this Mac keeps that profile's things.
///
/// A table of its own precisely so that it can never be named. SQLiteData's
/// `SyncEngine(for:tables:privateTables:)` lists tables and there is no filter below one, so a
/// device-local *column* is safe only until somebody opts its table in — while a device-local
/// *table* is safe by being left off a list. `id` is the profile's own id, one row to one profile.
///
/// A profile that arrives without one — the shape a synced profile would have — is given a new data
/// store on the spot, which is the right answer: cookies do not travel, so a profile met for the
/// first time on this Mac is signed out, as it should be.
@Table("profile_storage")
nonisolated struct ProfileStorage: Identifiable, Sendable, Hashable {
    let id: UUID
    var dataStoreID: UUID
    var workingDirectoryPath: String?
}

/// The profiles, read whole and written whole.
///
/// A handful of rows and a handful of edits a year, so there is nothing to gain by writing a column
/// at a time and something to lose: two tables and an order that disagree. Every edit hands the
/// whole list back and one transaction makes both tables equal to it.
nonisolated struct ProfileStore: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    /// Every profile, in the order they are shown, each joined to where this Mac keeps it. Empty on
    /// the launch that creates the tables — the one launch allowed to take the profiles elsewhere.
    func all() -> [ProfileRecord] {
        do {
            let (rows, storage) = try database.read { db in
                (try ProfileIdentity.all.order { $0.ord }.fetchAll(db),
                 try ProfileStorage.all.fetchAll(db))
            }
            let byID = Dictionary(storage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let records = rows.map { row in
                ProfileRecord(id: row.id, name: row.name, colorHex: row.colorHex,
                              dataStoreID: byID[row.id]?.dataStoreID ?? UUID(),
                              workingDirectoryPath: byID[row.id]?.workingDirectoryPath, ord: row.ord)
            }
            // A profile with no storage of its own has just been given one; write it down before
            // anything opens a page against it, or the next launch mints another.
            if records.contains(where: { byID[$0.id] == nil }) { save(records) }
            return records
        } catch {
            FileHandle.standardError.write(Data("[six] profiles load failed: \(error)\n".utf8))
            return []
        }
    }

    /// The list as it now stands: rows that are gone go, from both tables, and the rest are written
    /// with their place in the bar.
    ///
    /// An empty list is refused rather than obeyed. Nothing in the app can ask for one — the last
    /// profile cannot be removed — and the day something can, the table it would empty is the one
    /// that knows where the cookies are. A refusal costs a stale row; obeying costs every login.
    func save(_ records: [ProfileRecord]) {
        guard !records.isEmpty else {
            FileHandle.standardError.write(Data("[six] refusing to empty the profiles table\n".utf8))
            return
        }
        do {
            try database.write { db in
                let keep = Set(records.map(\.id))
                for row in try ProfileIdentity.all.fetchAll(db) where !keep.contains(row.id) {
                    try ProfileIdentity.where { $0.id.eq(row.id) }.delete().execute(db)
                }
                for row in try ProfileStorage.all.fetchAll(db) where !keep.contains(row.id) {
                    try ProfileStorage.where { $0.id.eq(row.id) }.delete().execute(db)
                }
                for (index, record) in records.enumerated() {
                    // `upsert`, not `insert`. The primary key is declared
                    // `TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE`, which reads as though a second
                    // insert would replace the first — but a conflict clause binds to the constraint
                    // in front of it, and that one is the `NOT NULL`. The key itself still aborts.
                    try ProfileIdentity.upsert {
                        ProfileIdentity(id: record.id, name: record.name, colorHex: record.colorHex, ord: index)
                    }.execute(db)
                    try ProfileStorage.upsert {
                        ProfileStorage(id: record.id, dataStoreID: record.dataStoreID,
                                          workingDirectoryPath: record.workingDirectoryPath)
                    }.execute(db)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[six] profiles save failed: \(error)\n".utf8))
        }
    }
}
