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
            return (String(localized: "Signed .crx, id \(extensionID) — the signature matches the file, but that says nothing about who owns the key."), false)
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

    /// What WebKit does with one thing an extension asked for.
    ///
    /// The *list* of things comes from the manifest — this is the only half six has to know by
    /// itself, and the only half that has to be revisited when WebKit gains something.
    private enum Support {
        /// Watched working here.
        case works
        /// WebKit implements nothing behind it.
        case missing
        /// Believed to work and never actually exercised, or exercised on one platform only.
        case unchecked
    }

    /// Permissions by what WebKit does with them here. A permission missing from this table is
    /// **not** listed at all: an unknown name is something six has never looked at, and an extension
    /// that asks for it deserves silence rather than a guess. `scripting` is the one that differs by
    /// platform — the phone has no live `WKWebView` to find (`WebViewResponder` is the Mac's).
    private static let permissionSupport: [WKWebExtension.Permission: Support] = {
        var table: [WKWebExtension.Permission: Support] = [
            .activeTab: .works, .alarms: .works, .clipboardWrite: .works, .contextMenus: .works,
            .cookies: .works, .declarativeNetRequest: .works, .declarativeNetRequestFeedback: .works,
            .declarativeNetRequestWithHostAccess: .works, .menus: .works, .storage: .works,
            .tabs: .works, .unlimitedStorage: .works, .webNavigation: .works,
            .webRequest: .missing,
            // six hosts no native messaging application, and nothing has been tried against one.
            .nativeMessaging: .unchecked,
        ]
        // On the Mac `WKWebExtensionTab.webView(for:)` answers now, which is what `scripting.*`
        // and content-script messaging were missing — but the re-test hit a wall one step short of
        // proving it, so this is "believed fixed" and says so (docs/extensions.md). The phone has
        // no view-tree walk of its own yet, so there it is simply absent.
        #if os(macOS)
        table[.scripting] = .unchecked
        #else
        table[.scripting] = .missing
        #endif
        return table
    }()

    /// A thing the manifest asked for, under the name it will be shown by. API names are set as
    /// code where they are printed; the manifest's own features are words and are not.
    private struct Named {
        let text: String
        let isAPI: Bool
    }

    /// The verdict, from the manifest alone (see `ExtensionCompatibility`).
    ///
    /// The lines used to be a sentence per case, written out by hand, which said the same thing
    /// twice (once in the summary, once under it) and named APIs the manifest never mentions. Now
    /// the manifest says what the extension asked for, the table above says what each of those does
    /// here, and both lines are those names joined — so an extension that asks for something new
    /// says so without a line being written for it.
    static func compatibility(of ext: WKWebExtension) -> ExtensionCompatibility {
        var bySupport: [Support: [Named]] = [:]
        for permission in ext.requestedPermissions.union(ext.optionalPermissions) {
            guard let support = permissionSupport[permission] else { continue }
            bySupport[support, default: []].append(Named(text: permission.rawValue, isAPI: true))
        }
        // What the manifest carries rather than asks for. Content scripts reach their extension on
        // the Mac (the tab→`WKWebView` map keyboard focus needed, reused here) and that has been
        // watched; messaging end to end has not, on any platform.
        if ext.hasInjectedContent {
            bySupport[.unchecked, default: []].append(Named(text: String(localized: "content scripts"), isAPI: false))
        }
        if ext.hasBackgroundContent {
            bySupport[.works, default: []].append(Named(text: String(localized: "background page"), isAPI: false))
        }
        if ext.hasContentModificationRules {
            bySupport[.works, default: []].append(Named(text: String(localized: "blocking rules"), isAPI: false))
        }

        let works = sorted(bySupport[.works])
        let missing = sorted(bySupport[.missing])
        let unchecked = sorted(bySupport[.unchecked])

        var details: [AttributedString] = []
        if !works.isEmpty { details.append(line("Works here: \(list(works))", naming: works)) }
        if !missing.isEmpty { details.append(line("Not in WebKit: \(list(missing))", naming: missing)) }
        if !unchecked.isEmpty { details.append(line("Unchecked here: \(list(unchecked))", naming: unchecked)) }

        // The summary is a verdict and the shortest possible reason, because the names are directly
        // under it: a summary long enough to wrap breaks mid-name, and `scripting.` at the end of
        // one line with `executeScript` at the start of the next reads as a different API.
        let verdict: ExtensionCompatibility.Verdict
        let summary: AttributedString
        if !missing.isEmpty, works.isEmpty {
            verdict = .unsupported
            summary = line("Does not work — WebKit has no \(list(missing))", naming: missing)
        } else if !missing.isEmpty {
            verdict = .partial
            summary = line("Works partly — WebKit has no \(list(missing))", naming: missing)
        } else if !unchecked.isEmpty {
            verdict = .partial
            summary = line("Works partly — \(list(unchecked)) unchecked", naming: unchecked)
        } else {
            verdict = .full
            summary = AttributedString(localized: "Works")
        }
        return ExtensionCompatibility(verdict: verdict, summary: summary, details: details)
    }

    private static func sorted(_ names: [Named]?) -> [Named] {
        (names ?? []).sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
    }

    private static func list(_ names: [Named]) -> String {
        names.map(\.text).formatted(.list(type: .and))
    }

    private static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }

    /// One line with the API names in it set as code, so a name is told apart from the sentence
    /// around it without a backtick being shown to anybody.
    private static func line(_ text: String.LocalizationValue, naming names: [Named]) -> AttributedString {
        var line = AttributedString(localized: text)
        for name in names.filter(\.isAPI).map(\.text) where !name.isEmpty {
            var searched = line.startIndex..<line.endIndex
            while let found = line[searched].range(of: name) {
                line[found].inlinePresentationIntent = .code
                searched = found.upperBound..<line.endIndex
            }
        }
        return line
    }
}
