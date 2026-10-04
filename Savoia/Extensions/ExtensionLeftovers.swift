import Foundation

/// What nothing else deletes: WebKit's extension storage for profiles and extensions that are gone,
/// rule lists whose compilation never finished, and unpacked extensions that are no longer installed.
nonisolated enum ExtensionLeftovers {
    /// `~/Library/WebKit/<bundle identifier>/WebExtensions/<profile's store id>/<extension id>`.
    static var webKitFolder: URL? {
        guard let bundle = Bundle.main.bundleIdentifier,
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return library.appending(path: "WebKit/\(bundle)/WebExtensions", directoryHint: .isDirectory)
    }

    /// What `remove` would delete, so the choice can be tested without touching a disk that matters.
    static func find(
        webKit: URL?, unpacked: URL, stores: Set<UUID>, extensions: Set<String>, before launch: Date
    ) -> [URL] {
        // An empty list is as likely a failed read as a browser with nothing installed.
        guard !extensions.isEmpty else { return [] }
        var found = folders(in: unpacked).filter { !extensions.contains($0.lastPathComponent) }
        let controllers = (webKit.map(folders(in:)) ?? []).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        let known = controllers.filter { stores.contains(UUID(uuidString: $0.lastPathComponent)!) }
        // No folder answering to a profile means the profiles in hand are not the ones on disk.
        guard !known.isEmpty else { return found }
        found += controllers.filter { !stores.contains(UUID(uuidString: $0.lastPathComponent)!) }
        for controller in known {
            for context in folders(in: controller) {
                guard extensions.contains(context.lastPathComponent) else { found.append(context); continue }
                found += unfinishedRuleLists(in: context, before: launch)
            }
        }
        return found
    }

    /// Returns the bytes it freed.
    @discardableResult
    static func remove(
        webKit: URL?, unpacked: URL, stores: Set<UUID>, extensions: Set<String>, before launch: Date
    ) -> Int {
        var freed = 0
        for url in find(webKit: webKit, unpacked: unpacked, stores: stores, extensions: extensions, before: launch) {
            let size = size(of: url)
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }

    /// WebKit compiles into `ContentRuleListXXXXXX` and renames; one that is still there was cut short.
    private static func unfinishedRuleLists(in context: URL, before launch: Date) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: context, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { file in
            let name = file.lastPathComponent
            guard name.hasPrefix("ContentRuleList"), name.count == "ContentRuleList".count + 6 else { return false }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return modified.map { $0 < launch } ?? false
        }
    }

    private static func folders(in url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func size(of url: URL) -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        let own = (try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return own }
        return walk.reduce(own) { total, item in
            total + (((try? (item as? URL)?.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize) ?? 0)
        }
    }
}
