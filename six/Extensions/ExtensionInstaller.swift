#if canImport(CryptoKit)
import CryptoKit
#else
// swift-crypto: the same SHA-256, so digests written by an Apple build read back identically.
import Crypto
#endif
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Getting an extension onto disk in the one shape `WKWebExtension` accepts: an unpacked folder with
/// a `manifest.json`.
///
/// Everything the world ships is a zip underneath — a `.crx` is a zip behind a small header, an
/// `.xpi` is a zip with a different name — so the work is unpacking, finding the manifest (archives
/// are not always flat), and copying the result into
/// `Application Support/org.deffun.six/Extensions/<id>/`. Extensions from the App Store are *not* a source:
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

    /// The same list as the open panel wants it. `.crx` and `.xpi` are nobody's registered type, and
    /// `UTType(filenameExtension:)` answers for them with a dynamic type that still matches by
    /// extension — which is exactly what the old `allowedFileTypes` did.
    static var acceptedContentTypes: [UTType] { acceptedTypes.compactMap { UTType(filenameExtension: $0) } }

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
        #if os(iOS)
        // No `ditto`, and no `Process` to run it with. Unpacking an archive on the phone waits for a
        // zip reader of our own — as does the file panel that would hand us one.
        throw Failure.unpackFailed(String(localized: "Archives cannot be unpacked on this device"))
        #elseif os(macOS)
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
        #endif
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

    /// A sentence for the install dialog about what a `.crx`'s own signature says, and whether it
    /// is a caption or a warning — `nil` for anything that is not a signed `.crx` (a folder, a
    /// `.zip`, an `.xpi`, or a `.crx` with no CRX3 header), which leaves the dialog's own
    /// disclaimer as the last word for those. The signature is the same on both platforms so the
    /// type this reads (`CRXSignature.Verdict`, macOS-only — the phone never reaches this call at
    /// all, but the function still has to compile there) never has to cross into a shared return
    /// type; `isWarning` rather than a colour, so the caller decides how orange means what here.
    static func crxSignatureSummary(of source: URL) -> (text: String, isWarning: Bool)? {
        #if os(macOS)
        guard let data = try? Data(contentsOf: source), data.count > 4, data.prefix(4) == Data("Cr24".utf8) else {
            return nil
        }
        switch CRXSignature.verify(data) {
        case .verified(let extensionID):
            return (String(localized: "Signed .crx, id \(extensionID) — the signature matches the file. Nobody vouches for who holds that key."), false)
        case .invalid:
            return (String(localized: "This .crx's signature does not match its contents — it was changed after it was signed."), true)
        case .malformed(let why):
            return (String(localized: "This .crx claims to be signed but the signature could not be read (\(why))."), true)
        case .notSigned:
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: What will and will not work

    /// The verdict, from the manifest alone (see `ExtensionCompatibility`).
    static func compatibility(of ext: WKWebExtension) -> ExtensionCompatibility {
        var details: [String] = []
        let wantsScripting = ext.requestedPermissions.contains(.scripting)
            || ext.optionalPermissions.contains(.scripting)
        let wantsWebRequest = ext.requestedPermissions.contains(.webRequest)
        let talksToPages = ext.hasInjectedContent && ext.hasBackgroundContent

        // Both used to fail for the identical reason — WebKit could not map a frame back to a tab
        // without the tab's own `WKWebView`, and `WebPage` handed none out. On macOS it now does
        // (`WebViewResponder`'s tab→`WKWebView` map, built for keyboard focus and reused here); the
        // phone has no equivalent yet. The messaging line is the less certain of the two: a purpose-
        // built test confirmed `scripting.insertCSS` reaches the page, but content-script-to-
        // background messaging through the same fix has not been exercised the same way — see
        // docs/extensions.md.
        if ext.hasInjectedContent {
            details.append(String(localized: "Its content scripts run in pages and should now reach their extension, and be reached back — on macOS; unconfirmed on the phone."))
        }
        if wantsScripting {
            details.append(String(localized: "`scripting.executeScript` and `scripting.insertCSS` now reach the page — on macOS; the phone has no live web view to find yet."))
        }
        if wantsWebRequest {
            details.append(String(localized: "`webRequest` is not available in WebKit at all."))
        }
        if ext.hasContentModificationRules {
            details.append(String(localized: "Its declarativeNetRequest rules work — those block for real."))
        }
        if ext.hasBackgroundContent {
            details.append(String(localized: "Background, storage, alarms, tabs and its popup work."))
        }

        // Kept apart rather than folded into one switch, because the two things that used to share a
        // summary no longer share a confidence level: `webRequest` is a wall WebKit never built a door
        // in, `scripting.*` is a door that opened on macOS and was watched opening (a purpose-built
        // test, `scripting.insertCSS` actually changing a real page), and messaging is the same door
        // with nobody yet standing on the other side to confirm it.
        let verdict: ExtensionCompatibility.Verdict
        let summary: String
        if wantsWebRequest {
            verdict = .partial
            summary = String(localized: "Works partly — `webRequest` is not available in WebKit at all.")
        } else if wantsScripting {
            verdict = .full
            summary = String(localized: "Works — `scripting.executeScript` and `scripting.insertCSS` reach the page on macOS.")
        } else if talksToPages {
            verdict = .partial
            summary = String(localized: "Works partly — its content scripts should now reach the extension on macOS, unconfirmed end to end.")
        } else {
            verdict = .full
            summary = String(localized: "Works — nothing it asks for depends on reaching into a page.")
        }

        // An extension that is *only* content scripts has nothing left when they go deaf.
        if ext.hasInjectedContent, !ext.hasBackgroundContent, !ext.hasContentModificationRules {
            return ExtensionCompatibility(
                verdict: .partial,
                summary: String(localized: "Works partly — it is content scripts, which run but cannot be configured or updated by it."),
                details: details)
        }
        return ExtensionCompatibility(verdict: verdict, summary: summary, details: details)
    }
}
