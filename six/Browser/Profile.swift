import Foundation
import SwiftUI

/// A browsing profile: its own cookies, storage and history, isolated via a persistent `WKWebsiteDataStore`.
nonisolated struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    /// Identifier of the persistent `WKWebsiteDataStore` backing this profile.
    var dataStoreID: UUID
    /// Where agents work for this profile when the user picked a folder; nil means the profile's
    /// scratchpad under Application Support (see `Profile.defaultWorkingDirectory`).
    var workingDirectoryPath: String?
    /// Private browsing: the data store is `nonPersistent()` — cookies, storage and caches live in memory
    /// and go with the profile — and nothing about it is recorded: no history, no bookmarks, no
    /// highlights, no place in the snapshot. It exists until it is closed or the app quits.
    var isPrivate = false

    init(id: UUID = UUID(), name: String, colorHex: String, dataStoreID: UUID = UUID(), isPrivate: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.dataStoreID = dataStoreID
        self.isPrivate = isPrivate
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorHex, dataStoreID, workingDirectoryPath, isPrivate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        dataStoreID = try c.decode(UUID.self, forKey: .dataStoreID)
        workingDirectoryPath = try c.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }

    static let privateName = "Private"
    static let privateColorHex = "#5C5C66"

    var color: Color { Color(hex: colorHex) }

    /// The folder six creates for this profile: `~/Library/Application Support/org.deffun.six/Profiles/<name>`.
    /// `Bookmarks/` and `Scratchpad/` live inside it.
    var folder: URL {
        let safeName = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return AppSupport.folder("Profiles/\(safeName.isEmpty ? id.uuidString : safeName)")
    }

    /// Where agents work unless the user picked a folder: `<folder>/Scratchpad`, a place for the files a
    /// run leaves behind. Deliberately not the profile folder itself, so the bookmarks next door are
    /// reached through the MCP tools (and their search), not by grepping the working directory.
    var defaultWorkingDirectory: URL {
        folder.appending(path: "Scratchpad", directoryHint: .isDirectory)
    }

    /// The folder agents work in for this profile.
    var workingDirectory: URL {
        workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultWorkingDirectory
    }

    var hasCustomWorkingDirectory: Bool { workingDirectoryPath != nil }

    static let defaults: [Profile] = [
        Profile(name: String(localized: "Personal"), colorHex: "#5B8DEF"),
        Profile(name: String(localized: "Work"), colorHex: "#E8743B"),
    ]
}

// MARK: The row it is kept as

extension Profile {
    /// A profile as the database has it. `isPrivate` is not among the columns and never will be:
    /// a private profile is the one that is written down nowhere, so anything read back is real.
    init(_ record: ProfileRecord) {
        self.init(id: record.id, name: record.name, colorHex: record.colorHex, dataStoreID: record.dataStoreID)
        workingDirectoryPath = record.workingDirectoryPath
    }
}

extension ProfileRecord {
    init(_ profile: Profile, ord: Int) {
        self.init(id: profile.id, name: profile.name, colorHex: profile.colorHex,
                  dataStoreID: profile.dataStoreID, workingDirectoryPath: profile.workingDirectoryPath,
                  ord: ord)
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
