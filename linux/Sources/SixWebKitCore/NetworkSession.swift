import CWebKitGTK
import Foundation

/// A profile's cookies, caches and storage.
///
/// The direct counterpart of `WKWebsiteDataStore(forIdentifier:)` on the Mac: one per profile, and an
/// ephemeral one for a private profile, which is the same arrangement six already has there. A
/// private profile records nothing because its session records nothing, not because the app
/// remembers to skip writes.
///
/// `nonisolated` against the module's default: a `deinit` cannot be actor-isolated, and this class is
/// only a handle — `g_object_unref` is thread-safe, and nothing else here touches GTK.
public nonisolated final class NetworkSession: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer

    /// A profile that keeps what it collects, under a directory of its own.
    public init(directory: URL) {
        let data = directory.appending(path: "data", directoryHint: .isDirectory).path
        let cache = directory.appending(path: "cache", directoryHint: .isDirectory).path
        pointer = UnsafeMutableRawPointer(webkit_network_session_new(data, cache)!)
    }

    /// Private browsing: in memory, and gone with the profile.
    public init() {
        pointer = UnsafeMutableRawPointer(webkit_network_session_new_ephemeral()!)
    }

    deinit { g_object_unref(pointer) }

    public var isEphemeral: Bool { webkit_network_session_is_ephemeral(.init(pointer)) != 0 }
}
