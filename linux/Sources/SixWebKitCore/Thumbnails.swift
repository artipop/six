import CWebKitGTK
import Foundation

/// `SIX_UI_DEBUG=1`, the same switch the model and `NiriLayout` use.
///
/// A free function rather than a member: the snapshot's completion is a `@convention(c)` function
/// pointer, and one of those cannot be formed from anything that captures context — which a method
/// on an actor-isolated type does.
func thumbnailTrace(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data("[six] thumb: \(message())\n".utf8))
}

/// A picture of a page, so a column that has given up its process still has something to show.
///
/// The Mac does exactly this and for exactly this reason: an overview full of blank cards after a
/// relaunch is the moment thumbnails were invented for. Its pictures live under
/// `Application Support/…/Thumbnails/<column>.png`; these live under the same relative path inside
/// whatever `AppSupport.root` resolves to, which on Linux is `~/.local/share/six`.
///
/// Taken on the way *out* — before a page is discarded — because a page that is already gone has
/// nothing left to photograph.
@MainActor
public enum Thumbnails {
    /// Where the pictures go. The caller passes the folder so this module stays free of `SixCore`,
    /// which reaches GRDB and must not meet Adwaita's SQLite.
    public nonisolated(unsafe) static var folder: URL?

    public static func url(for tabID: UUID) -> URL? {
        folder?.appending(path: tabID.uuidString + ".png")
    }

    /// Whether there is a picture on disk for this column.
    public static func exists(for tabID: UUID) -> Bool {
        guard let url = url(for: tabID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Photograph a page and write it out. Asynchronous in GTK's own terms — the snapshot is taken
    /// by the web process and arrives on the main loop — so the result is delivered to a callback
    /// rather than returned.
    public static func capture(_ tabID: UUID, then done: (() -> Void)? = nil) {
        guard let page = PageRegistry.page(for: tabID) else {
            thumbnailTrace("no page for \(tabID.uuidString.prefix(8))")
            done?()
            return
        }
        guard let destination = url(for: tabID) else {
            thumbnailTrace("no folder")
            done?()
            return
        }
        thumbnailTrace("capturing \(tabID.uuidString.prefix(8))")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let box = Unmanaged.passRetained(Request(tabID: tabID, destination: destination, done: done)).toOpaque()
        webkit_web_view_get_snapshot(
            page,
            WEBKIT_SNAPSHOT_REGION_VISIBLE,
            // Nothing beyond the visible region, and no re-render for it: this is a picture of what
            // is already on screen, not a reason to lay the page out again.
            WEBKIT_SNAPSHOT_OPTIONS_NONE,
            nil,
            { source, result, data in
                guard let data else { return }
                let request = Unmanaged<Request>.fromOpaque(data).takeRetainedValue()
                guard let view = source else { return request.done?() ?? () }
                var error: UnsafeMutablePointer<GError>?
                let texture = webkit_web_view_get_snapshot_finish(
                    UnsafeMutableRawPointer(view).assumingMemoryBound(to: WebKitWebView.self),
                    result,
                    &error
                )
                if let texture {
                    let ok = gdk_texture_save_to_png(texture, request.destination.path)
                    thumbnailTrace("saved \(ok != 0) -> \(request.destination.lastPathComponent)")
                    g_object_unref(UnsafeMutableRawPointer(texture))
                }
                if let error {
                    thumbnailTrace("failed: \(String(cString: error.pointee.message))")
                    g_error_free(error)
                }
                request.done?()
            },
            box
        )
    }

    /// What the caller wanted, kept alive across the round trip through C.
    private final class Request {
        let tabID: UUID
        let destination: URL
        let done: (() -> Void)?
        init(tabID: UUID, destination: URL, done: (() -> Void)?) {
            self.tabID = tabID
            self.destination = destination
            self.done = done
        }
    }

    /// Drop the pictures of columns that no longer exist — one file per open column and no more,
    /// which is what keeps the folder from growing without end.
    public static func prune(keeping ids: Set<UUID>) {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "png" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
