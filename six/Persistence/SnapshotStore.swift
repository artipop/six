import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// A file under `Application Support/org.deffun.six/` (`~/.local/share/six/` on Linux).
    init(fileNamed name: String) {
        url = AppSupport.file(name)
    }

    func load() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version <= Snapshot.currentVersion else { return nil }
            return snapshot
        } catch {
            // A file that will not decode is kept, not overwritten. The caller starts fresh and the
            // autosave writes a new snapshot a second later, so without this the bytes that failed
            // are gone before anyone can read them — and they are the only record of what was open.
            setAside()
            throw error
        }
    }

    /// The unreadable file, moved next to itself with the hour it was set aside.
    private func setAside() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let kept = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: kept)
            FileHandle.standardError.write(Data("[six] kept the unreadable snapshot at \(kept.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[six] could not keep the unreadable snapshot: \(error)\n".utf8))
        }
    }

    func save(_ snapshot: Snapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // `Data.write(.atomic)` renames a temporary file into place but never flushes it, so a
        // machine that goes down unclean can come back with the rename and none of the bytes behind
        // it — a snapshot of nothing, which the loader can only read as "start fresh". Write it,
        // make it durable, and only then let it take the name.
        let temporary = folder.appending(path: ".\(url.lastPathComponent).writing")
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}
