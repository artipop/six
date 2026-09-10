import Foundation
import GRDB

/// The `vec0` table, and the four things anyone does to it.
///
/// Lifted out of `BookmarkStore` so that a front which is not the Mac can write vectors the Mac will
/// read: the table name, the column layout, the blob format and the KNN are the index's contract
/// with the file, and a second implementation of them is a second chance to get one of them wrong.
/// What is *not* here is everything `BookmarkStore` does around it — the readable copy, the
/// chunking, the queue, the model that makes the vectors — because those are per front and this is
/// not.
///
/// **No sqlite-vec dependency, on purpose.** Every statement below is SQL, so this file compiles
/// everywhere `SixCore` does, including the Linux build that cannot link `CSQLiteVec` at all
/// (`linux/Package.swift` says why). What it needs instead is a connection that has the extension
/// loaded, which is each front's own first line: `Database.loadSQLiteVecExtension` on Apple, where
/// the system SQLite refuses process-global registration, and `registerSQLiteVecAutoExtension`
/// everywhere else, where the extension is compiled as a loadable one and a null API table is a
/// crash rather than a fallback. `selfTest` is the answer to "which of those happened here".
///
/// One table per dimension — `bookmark_vec_384` for `multilingual-e5-small`, `bookmark_vec_768` for
/// `-base` — because a `vec0` column's width is fixed at creation. Two models of the same width
/// share a table and are told apart by `model`, which is why every query carries it.
nonisolated struct VectorIndex {
    /// How wide a vector in this index is; the table's name and its `FLOAT[…]` column both come
    /// from it.
    let dimension: Int

    var table: String { "bookmark_vec_\(dimension)" }

    init(dimension: Int) {
        self.dimension = dimension
    }

    /// Creates the table if this is the first time six has seen this dimension.
    ///
    /// `profile_id` is a `PARTITION KEY` rather than a plain column: sqlite-vec keeps a partition's
    /// rows apart on disk, so a search scoped to one profile never reads another profile's vectors
    /// instead of reading and discarding them.
    func create(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS "\(table)" USING vec0(
              chunk_id TEXT PRIMARY KEY,
              profile_id TEXT PARTITION KEY,
              model TEXT,
              embedding FLOAT[\(dimension)] distance_metric=cosine
            )
            """)
    }

    /// One vector. The ids are written lower-case because that is how SQLiteData writes a `UUID`
    /// into the rest of the schema, and `chunk_id` is joined against those rows by string.
    func insert(
        _ vector: [Float], chunkID: UUID, profileID: UUID, model: String, in db: Database
    ) throws {
        guard vector.count == dimension else {
            throw EmbedderError.dimensionMismatch(expected: dimension, got: vector.count)
        }
        try db.execute(
            sql: "INSERT INTO \"\(table)\"(chunk_id, profile_id, model, embedding) VALUES (?, ?, ?, ?)",
            arguments: [chunkID.uuidString.lowercased(), profileID.uuidString.lowercased(), model, Self.blob(vector)]
        )
    }

    /// Drops whatever is held for these chunks. Called before re-embedding them, and when the
    /// bookmark they belong to goes away — a `vec0` table has no foreign keys to do it for us.
    func remove(chunkIDs: [UUID], in db: Database) throws {
        for id in chunkIDs {
            try db.execute(
                sql: "DELETE FROM \"\(table)\" WHERE chunk_id = ?",
                arguments: [id.uuidString.lowercased()]
            )
        }
    }

    /// The KNN: cosine distance, nearest first, this model's vectors only.
    ///
    /// `profileID` scopes the search to one partition; `nil` searches every profile, which is what
    /// the Mac's "all profiles" bookmark scope asks for. `k` is sqlite-vec's own limit and it is a
    /// limit on *chunks* — a caller that wants k documents asks for more than k here, because one
    /// document can own several of the nearest passages.
    func search(
        _ vector: [Float], model: String, profileID: UUID?, k: Int, in db: Database
    ) throws -> [(chunkID: UUID, distance: Double)] {
        var sql = "SELECT chunk_id, distance FROM \"\(table)\" WHERE embedding MATCH ? AND k = ? AND model = ?"
        var arguments: StatementArguments = [Self.blob(vector), k, model]
        if let profileID {
            sql += " AND profile_id = ?"
            arguments += [profileID.uuidString.lowercased()]
        }
        return try Row.fetchAll(db, sql: sql + " ORDER BY distance", arguments: arguments)
            .compactMap { row in UUID(uuidString: row["chunk_id"]).map { ($0, row["distance"] as Double) } }
    }

    /// A vector as sqlite-vec wants it: the floats themselves, little-endian, and nothing else.
    /// Identical to what `BookmarkStore` writes, which is the point of it being one function.
    static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Saying whether it is there at all

    /// Whether this connection has sqlite-vec in it, and which version.
    ///
    /// Cheap, and worth asking before the first write rather than after: a connection without the
    /// extension does not fail at `INSERT`, it fails at `CREATE VIRTUAL TABLE` with "no such
    /// module: vec0", by which point whoever asked has already been told the index exists.
    static func version(in db: Database) -> String? {
        try? String.fetchOne(db, sql: "SELECT vec_version()")
    }

    /// `SIX_VEC_SELFTEST=1`: does this build have a working vector index, and does it rank.
    ///
    /// Every front needs the same answer and none of them can get it by reading the source — the
    /// extension is loaded by a call in a package this file cannot see, and the ways it can fail
    /// (missing module, a null API table, a dimension the table was not made for) all look like a
    /// database error several layers away from the cause. So it is asked in one place, out loud,
    /// against a real connection: build a table, put three vectors in it, and check that the one
    /// pointing the same way as the query comes back first.
    ///
    /// The table is temporary and named after nothing else, so running this against the real
    /// database costs a page and leaves it as it was.
    static func selfTest(in database: any DatabaseWriter) -> String {
        var lines: [String] = []
        do {
            try database.write { db in
                guard let version = version(in: db) else {
                    lines.append("vec_version: absent — sqlite-vec is not in this connection")
                    return
                }
                lines.append("vec_version: \(version)")
                let index = VectorIndex(dimension: 4)
                try db.execute(sql: "DROP TABLE IF EXISTS \"\(index.table)_selftest\"")
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE "\(index.table)_selftest" USING vec0(
                      chunk_id TEXT PRIMARY KEY,
                      profile_id TEXT PARTITION KEY,
                      model TEXT,
                      embedding FLOAT[4] distance_metric=cosine
                    )
                    """)
                let profile = UUID()
                let samples: [(UUID, [Float])] = [
                    (UUID(), [1, 0, 0, 0]),
                    (UUID(), [0, 1, 0, 0]),
                    (UUID(), [0.9, 0.1, 0, 0])
                ]
                for (id, vector) in samples {
                    try db.execute(
                        sql: "INSERT INTO \"\(index.table)_selftest\"(chunk_id, profile_id, model, embedding) VALUES (?, ?, ?, ?)",
                        arguments: [id.uuidString.lowercased(), profile.uuidString.lowercased(), "selftest", blob(vector)]
                    )
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT chunk_id, distance FROM "\(index.table)_selftest"
                        WHERE embedding MATCH ? AND k = ? AND model = ? AND profile_id = ? ORDER BY distance
                        """,
                    arguments: [blob([1, 0, 0, 0]), 3, "selftest", profile.uuidString.lowercased()]
                )
                lines.append("rows: \(rows.count)")
                for row in rows {
                    let id = (row["chunk_id"] as String?) ?? "?"
                    let distance = (row["distance"] as Double?) ?? .nan
                    let which = samples.firstIndex { $0.0.uuidString.lowercased() == id }.map(String.init) ?? "?"
                    lines.append(String(format: "  sample %@  distance %.4f", which, distance))
                }
                let nearest = (rows.first?["chunk_id"] as String?) ?? ""
                let ranks = nearest == samples[0].0.uuidString.lowercased()
                lines.append(ranks ? "ranking: ok — the identical vector came back first" : "ranking: WRONG — nearest was \(nearest)")
                try db.execute(sql: "DROP TABLE \"\(index.table)_selftest\"")
            }
        } catch {
            lines.append("failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
