import CryptoKit
import Foundation
import WebKit

/// Getting an extension onto disk in the one shape `WKWebExtension` accepts: an unpacked folder with
/// a `manifest.json`.
///
/// Everything the world ships is a zip underneath — a `.crx` is a zip behind a small header, an
/// `.xpi` is a zip with a different name — so the work is unpacking, finding the manifest (archives
/// are not always flat), and copying the result into
/// `Application Support/six/Extensions/<id>/`. Extensions from the App Store are *not* a source:
/// those are app extensions belonging to their own host apps, and `WKWebExtension(appExtensionBundle:)`
/// is for one shipped inside six.
enum ExtensionInstaller {
    enum Failure: LocalizedError {
        case noManifest
        case unpackFailed(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noManifest: "No manifest.json — this does not look like a browser extension."
            case .unpackFailed(let why): "Could not unpack the archive: \(why)"
            case .unreadable(let why): "Could not read the extension: \(why)"
            }
        }
    }

    static let acceptedTypes = ["zip", "crx", "xpi"]

    /// Copies (or unpacks) whatever the user picked into six's extensions folder and answers with the
    /// folder that holds the manifest. Nothing is loaded here — that is `ExtensionStore`'s work.
    static func stage(_ source: URL) throws -> (folder: URL, id: String) {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "six-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw Failure.unreadable(source.lastPathComponent)
        }

        let unpacked: URL
        if isDirectory.boolValue {
            unpacked = source
        } else {
            let zip = try zipData(from: source)
            let archive = scratch.appending(path: "archive.zip")
            try zip.write(to: archive)
            let destination = scratch.appending(path: "unpacked", directoryHint: .isDirectory)
            try unzip(archive, into: destination)
            unpacked = destination
        }

        guard let manifestFolder = folderWithManifest(in: unpacked) else { throw Failure.noManifest }

        // The id is the extension's identity for the whole of six: the folder name, and the
        // context's `uniqueIdentifier`, which is what keeps its storage across relaunches. Derived
        // from the manifest's name and version so that reinstalling the same extension replaces it.
        let manifest = try Data(contentsOf: manifestFolder.appending(path: "manifest.json"))
        let name = (try? JSONSerialization.jsonObject(with: manifest) as? [String: Any])??["name"] as? String
        let id = digest(of: (name ?? source.lastPathComponent) + (source.lastPathComponent))

        try FileManager.default.createDirectory(at: InstalledExtension.folder, withIntermediateDirectories: true)
        let target = InstalledExtension.folder.appending(path: id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: manifestFolder, to: target)
        return (target, id)
    }

    /// A `.crx` is `Cr24`, a version, a header, then the zip. The signature in that header is *not*
    /// checked — six has no key to check it against — which is why the install dialog says outright
    /// where the file came from and that nothing vouches for it.
    private static func zipData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8) else { return data }
        func word(at offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        let version = word(at: 4)
        switch version {
        case 2:
            // Cr24 | version | public key length | signature length | key | signature | zip
            let start = 16 + word(at: 8) + word(at: 12)
            guard start < data.count else { throw Failure.unpackFailed("truncated .crx") }
            return data.subdata(in: start..<data.count)
        case 3:
            // Cr24 | version | header length | header | zip
            let start = 12 + word(at: 8)
            guard start < data.count else { throw Failure.unpackFailed("truncated .crx") }
            return data.subdata(in: start..<data.count)
        default:
            throw Failure.unpackFailed("unknown .crx version \(version)")
        }
    }

    /// `ditto` rather than a zip library: it ships with the OS, it handles what the world produces,
    /// and an extension archive is not a place to be clever.
    private static func unzip(_ archive: URL, into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.unpackFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Archives are not always flat: a `.crx` unpacks into its contents, a `.zip` from a release page
    /// often has one folder inside. Looks two levels deep, which covers both.
    private static func folderWithManifest(in root: URL) -> URL? {
        if FileManager.default.fileExists(atPath: root.appending(path: "manifest.json").path) { return root }
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if FileManager.default.fileExists(atPath: entry.appending(path: "manifest.json").path) { return entry }
        }
        return nil
    }

    private static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: What will and will not work

    /// The verdict, from the manifest alone (see `ExtensionCompatibility`).
    static func compatibility(of ext: WKWebExtension) -> ExtensionCompatibility {
        var details: [String] = []
        let wantsScripting = ext.requestedPermissions.contains(.scripting)
            || ext.optionalPermissions.contains(.scripting)
        let wantsWebRequest = ext.requestedPermissions.contains(.webRequest)
        let talksToPages = ext.hasInjectedContent && ext.hasBackgroundContent

        if ext.hasInjectedContent {
            details.append("Its content scripts run in pages, but cannot message the extension — and it cannot message them.")
        }
        if wantsScripting {
            details.append("`scripting.executeScript` and `scripting.insertCSS` fail here; scripts it registers do run.")
        }
        if wantsWebRequest {
            details.append("`webRequest` is not available in WebKit at all.")
        }
        if ext.hasContentModificationRules {
            details.append("Its declarativeNetRequest rules work — those block for real.")
        }
        if ext.hasBackgroundContent {
            details.append("Background, storage, alarms, tabs and its popup work.")
        }

        let verdict: ExtensionCompatibility.Verdict
        let summary: String
        switch (talksToPages || wantsWebRequest, ext.hasInjectedContent || wantsScripting) {
        case (true, _):
            verdict = .partial
            summary = "Works partly — anything it does inside a page will be broken."
        case (false, true):
            verdict = .partial
            summary = "Works partly — its content scripts run, but it cannot reach into pages beyond them."
        default:
            verdict = .full
            summary = "Works — nothing it asks for depends on reaching into a page."
        }

        // An extension that is *only* content scripts has nothing left when they go deaf.
        if ext.hasInjectedContent, !ext.hasBackgroundContent, !ext.hasContentModificationRules {
            return ExtensionCompatibility(
                verdict: .partial,
                summary: "Works partly — it is content scripts, which run but cannot be configured or updated by it.",
                details: details)
        }
        return ExtensionCompatibility(verdict: verdict, summary: summary, details: details)
    }
}
