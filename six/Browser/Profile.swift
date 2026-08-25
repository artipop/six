import Foundation
import SwiftUI

/// A browsing profile: its own cookies, storage and history, isolated via a persistent `WKWebsiteDataStore`.
struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    /// Identifier of the persistent `WKWebsiteDataStore` backing this profile.
    var dataStoreID: UUID
    /// Where agents work for this profile when the user picked a folder; nil means the profile's own
    /// folder under Application Support (see `Profile.defaultWorkingDirectory`).
    var workingDirectoryPath: String?

    init(id: UUID = UUID(), name: String, colorHex: String, dataStoreID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.dataStoreID = dataStoreID
    }

    var color: Color { Color(hex: colorHex) }

    /// The folder six creates for this profile: `~/Library/Application Support/six/Profiles/<name>`.
    var defaultWorkingDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safeName = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return support.appending(path: "six/Profiles/\(safeName.isEmpty ? id.uuidString : safeName)", directoryHint: .isDirectory)
    }

    /// The folder agents work in for this profile.
    var workingDirectory: URL {
        workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultWorkingDirectory
    }

    var hasCustomWorkingDirectory: Bool { workingDirectoryPath != nil }

    static let defaults: [Profile] = [
        Profile(name: "Personal", colorHex: "#5B8DEF"),
        Profile(name: "Work", colorHex: "#E8743B"),
    ]
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
