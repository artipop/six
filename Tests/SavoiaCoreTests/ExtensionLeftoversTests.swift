import Foundation
import Testing
@testable import SavoiaCore

struct ExtensionLeftoversTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "savoia-leftovers-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let profile = UUID()
    private let gone = UUID()
    private let launch = Date.now

    private var webKit: URL { root.appending(path: "WebExtensions", directoryHint: .isDirectory) }
    private var unpacked: URL { root.appending(path: "Extensions", directoryHint: .isDirectory) }

    private func write(_ path: String, in folder: URL, modified: Date? = nil) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
    }

    /// One live profile with the installed extension, and one of everything that should go.
    private func layOut() throws {
        try write("\(profile.uuidString)/current/State.plist", in: webKit)
        try write("\(profile.uuidString)/current/ContentRuleListAbC123", in: webKit, modified: launch - 60)
        try write("\(profile.uuidString)/current/ContentRuleListNow456", in: webKit, modified: launch + 60)
        try write("\(profile.uuidString)/current/DeclarativeNetRequestContentRuleList.data", in: webKit, modified: launch - 60)
        try write("\(profile.uuidString)/old/State.plist", in: webKit)
        try write("\(gone.uuidString)/current/State.plist", in: webKit)
        try write("not-a-store/current/State.plist", in: webKit)
        try write("current/manifest.json", in: unpacked)
        try write("old/manifest.json", in: unpacked)
    }

    private func found(stores: Set<UUID>, extensions: Set<String>) -> Set<String> {
        let all = ExtensionLeftovers.find(webKit: webKit, unpacked: unpacked, stores: stores, extensions: extensions, before: launch)
        return Set(all.map { $0.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "") })
    }

    @Test func findsWhatBelongsToNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try layOut()
        #expect(found(stores: [profile], extensions: ["current"]) == [
            "Extensions/old",
            "WebExtensions/\(gone.uuidString)",
            "WebExtensions/\(profile.uuidString)/old",
            "WebExtensions/\(profile.uuidString)/current/ContentRuleListAbC123",
        ])
    }

    @Test func touchesNothingWhenTheListOfExtensionsIsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try layOut()
        #expect(found(stores: [profile], extensions: []).isEmpty)
    }

    @Test func leavesWebKitAloneWhenNoFolderAnswersToAProfile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try layOut()
        #expect(found(stores: [UUID()], extensions: ["current"]) == ["Extensions/old"])
    }

    @Test func findsAnExtensionsStorageInEveryProfile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try layOut()
        let all = ExtensionLeftovers.storage(of: "current", webKit: webKit)
        let names = Set(all.map { $0.deletingLastPathComponent().lastPathComponent })
        #expect(names == [profile.uuidString, gone.uuidString, "not-a-store"])
        #expect(all.allSatisfy { $0.lastPathComponent == "current" })
        #expect(ExtensionLeftovers.storage(of: "", webKit: webKit).isEmpty)
    }

    @Test func removesWhatItFoundAndKeepsTheRest() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try layOut()
        let freed = ExtensionLeftovers.remove(webKit: webKit, unpacked: unpacked, stores: [profile], extensions: ["current"], before: launch)
        #expect(freed > 0)
        #expect(found(stores: [profile], extensions: ["current"]).isEmpty)
        let kept = ["State.plist", "ContentRuleListNow456", "DeclarativeNetRequestContentRuleList.data"]
        for name in kept {
            #expect(FileManager.default.fileExists(atPath: webKit.appending(path: "\(profile.uuidString)/current/\(name)").path))
        }
        #expect(FileManager.default.fileExists(atPath: webKit.appending(path: "not-a-store/current/State.plist").path))
        #expect(FileManager.default.fileExists(atPath: unpacked.appending(path: "current/manifest.json").path))
    }
}
