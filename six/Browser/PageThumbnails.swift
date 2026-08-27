#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The pictures of the pages, on disk — one PNG per window, named by its id.
///
/// A picture outlives the page it was taken of (that is the whole point of `LivePageCache`), and it
/// should outlive the launch too: opening the overview after a relaunch and finding a wall of blank
/// cards is exactly the moment the pictures were for. Every browser that shows thumbnails keeps them
/// as files — Firefox's `moz-page-thumbnails`, Safari's snapshots under Caches — for the same reason.
///
/// They are read back lazily, when the overview asks, and never all at once: a strip of a hundred
/// windows is a hundred files nobody has looked at yet. What bounds the folder is the strip itself —
/// `prune(keeping:)` throws away the pictures of windows that no longer exist, at launch and when a
/// window closes.
@MainActor
final class PageThumbnails {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "six/Thumbnails", directoryHint: .isDirectory)
    }()

    private static func url(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).png")
    }

    /// Windows looked up and found to have no picture, so a window that never had one is not looked
    /// for again every time the overview opens. A picture dropped from memory for the budget is not
    /// in here: reading it back from disk is exactly what the folder is for.
    private var missing: Set<UUID> = []

    /// Keeps the PNG. Off the main thread: it is a couple of hundred kilobytes and nobody is waiting.
    func write(_ data: Data, for id: UUID) {
        missing.remove(id)
        let url = Self.url(for: id)
        let folder = Self.folder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// The picture of a window from an earlier launch, if there is one. Nil the second time it is
    /// asked for a window that has none.
    func read(_ id: UUID) async -> PlatformImage? {
        guard !missing.contains(id) else { return nil }
        let url = Self.url(for: id)
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let image = PlatformImage(data: data), image.size.width > 1 else {
            missing.insert(id)
            return nil
        }
        return image
    }

    func remove(_ id: UUID) {
        missing.insert(id)
        let url = Self.url(for: id)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }

    /// Drops the pictures of windows that are gone — closed while the app wasn't running, or closed
    /// in a launch that never got to clean up.
    func prune(keeping ids: Set<UUID>) {
        let names = Set(ids.map { "\($0.uuidString).png" })
        let folder = Self.folder
        Task.detached(priority: .background) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for file in files where !names.contains(file.lastPathComponent) {
                try? manager.removeItem(at: file)
            }
        }
    }
}
