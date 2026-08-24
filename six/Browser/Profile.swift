import Foundation
import SwiftUI

/// A browsing profile: its own cookies, storage and history, isolated via a persistent `WKWebsiteDataStore`.
struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    /// Identifier of the persistent `WKWebsiteDataStore` backing this profile.
    var dataStoreID: UUID

    init(id: UUID = UUID(), name: String, colorHex: String, dataStoreID: UUID = UUID()) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.dataStoreID = dataStoreID
    }

    var color: Color { Color(hex: colorHex) }

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
