import Foundation

import GRDB

@testable internal import SixCore

/// Saved pages, over the same `bookmarks` table the Mac writes.
///
/// Deliberately less than the Mac's `BookmarkStore`, and the missing parts are the ones that are out
/// of scope rather than the ones that were hard: no readable Markdown copy, no chunking, no
/// embedding, no vector search. Those need `ReadablePage` (which runs JavaScript in the page) and an
/// `Embedder`, and both were put outside this phase.
///
/// What is here is the record itself — the row, in the shared schema, with the same columns and the
/// same profile scoping. A bookmark saved on Linux is a row the Mac's store can read, index and
/// search later; the columns it fills in are simply the ones a browser knows without reading the
/// page again.
struct Bookmarks {
    let database: any DatabaseWriter

    /// Save the page a column is on. `createdAt` and the identifiers are the only things invented
    /// here; the rest is what the page already told us.
    func add(url: URL, title: String, profileID: UUID) throws {
        let bookmark = Bookmark(
            id: UUID(),
            profileID: profileID,
            url: url,
            title: title,
            siteName: url.host() ?? "",
            createdAt: Date()
        )
        try database.write { db in
            try Bookmark.insert { bookmark }.execute(db)
        }
    }

    func remove(_ id: UUID) throws {
        try database.write { db in
            try Bookmark.where { $0.id.eq(id) }.delete().execute(db)
        }
    }

    /// This profile's bookmarks, newest first. A search matches the title or the address — the
    /// Mac searches the readable text too, which is what the embeddings are for.
    func all(in profileID: UUID, matching query: String = "") throws -> [Bookmark] {
        try database.read { db in
            let rows = try Bookmark
                .where { $0.profileID.eq(profileID) }
                .order { $0.createdAt.desc() }
                .fetchAll(db)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return rows }
            return rows.filter {
                $0.title.lowercased().contains(trimmed)
                    || $0.url.absoluteString.lowercased().contains(trimmed)
            }
        }
    }

    /// Whether this address is already saved, so the star can say so.
    func contains(_ url: URL, in profileID: UUID) throws -> Bool {
        try database.read { db in
            try Bookmark
                .where { $0.profileID.eq(profileID) }
                .where { $0.url.eq(url) }
                .fetchCount(db) > 0
        }
    }
}
