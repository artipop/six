import Foundation

/// The browser was called six until September 2026; its files move across once, on the first
/// launch under the new name, and never again once the new ones exist.
nonisolated enum FormerName {
    static let identifier = "org.deffun.six"
    static let database = ["six.sqlite", "six.sqlite-wal", "six.sqlite-shm"]

    /// The folder and the database inside it. Safe to call on every launch.
    static func adopt(folder former: URL, into current: URL) {
        let files = FileManager.default
        if !files.fileExists(atPath: current.path), files.fileExists(atPath: former.path) {
            try? files.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try files.moveItem(at: former, to: current)
            } catch {
                FileHandle.standardError.write(Data("[Savoia] could not adopt \(former.path): \(error)\n".utf8))
            }
        }
        guard !files.fileExists(atPath: current.appending(path: "savoia.sqlite").path) else { return }
        for name in database where files.fileExists(atPath: current.appending(path: name).path) {
            let renamed = "savoia" + name.dropFirst("six".count)
            try? files.moveItem(at: current.appending(path: name), to: current.appending(path: renamed))
        }
    }

    #if os(macOS)
    /// Everything keyed by the bundle identifier: Application Support, WebKit's site data and
    /// cookies, and the preferences. Runs before anything in the app has opened any of them.
    static func adoptOnMac() {
        guard let current = Bundle.main.bundleIdentifier, current.hasPrefix("org.deffun.savoia") else { return }
        let former = identifier + current.dropFirst("org.deffun.savoia".count)
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        adopt(folder: library.appending(path: "Application Support/\(former)"), into: AppSupport.root)
        for place in ["WebKit", "HTTPStorages"] {
            let target = library.appending(path: "\(place)/\(current)")
            let source = library.appending(path: "\(place)/\(former)")
            if !FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: target)
            }
        }
        let defaults = UserDefaults.standard
        if defaults.persistentDomain(forName: current)?.isEmpty ?? true,
           let old = defaults.persistentDomain(forName: former), !old.isEmpty {
            var renamed: [String: Any] = [:]
            for (key, value) in old {
                renamed[key.hasPrefix("six.") ? "savoia." + key.dropFirst("six.".count) : key] = value
            }
            defaults.setPersistentDomain(renamed, forName: current)
        }
    }
    #endif
}
