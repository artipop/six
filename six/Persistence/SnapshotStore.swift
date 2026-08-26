import Foundation

/// Something with a format version, so an older build can refuse a newer file instead of guessing.
nonisolated protocol VersionedSnapshot: Codable, Sendable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

/// Where a snapshot lives. One file today; the protocol is the seam for anything else.
nonisolated protocol SnapshotStore: Sendable {
    associatedtype Snapshot: VersionedSnapshot
    func load() throws -> Snapshot?
    func save(_ snapshot: Snapshot) throws
}

/// One pretty-printed JSON file, written atomically. Readable and diffable, which is worth more than
/// speed for a few hundred windows.
nonisolated struct FileSnapshotStore<Snapshot: VersionedSnapshot>: SnapshotStore {
    let url: URL

    /// A file under `Application Support/six/` (`~/.local/share/six/` on Linux).
    init(fileNamed name: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appending(path: "six/\(name)")
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version <= Snapshot.currentVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
