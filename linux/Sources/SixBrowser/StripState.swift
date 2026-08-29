import Foundation

@testable internal import SixCore

/// The strip as it was left, so a relaunch opens where the last one closed.
///
/// In the `settings` table rather than a file beside it. The Mac keeps this in `state.json`, and
/// that file is fine there — but a front that has no snapshot machinery yet gets the durable thing
/// for free by using the database that is already open, already migrated, and already the place
/// every other preference lives.
///
/// What is stored is `NiriStrip` itself — the same `Codable` type the Mac writes, unchanged — plus
/// the address each column was on. The layout is the shape; the addresses are what makes the shape
/// mean something after a restart.
struct StripState: Codable {
    var strips: [String: NiriStrip] = [:]
    var urls: [String: String] = [:]
    var titles: [String: String] = [:]
    var activeProfile: String = ""

    static func load(from settings: SettingsStore) -> StripState? {
        guard let json = settings[.stripState], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StripState.self, from: data)
    }

    func save(to settings: SettingsStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        settings[.stripState] = String(decoding: data, as: UTF8.self)
    }

    /// A column with no address is a column that cannot be rebuilt, so it is not worth restoring —
    /// the strip would come back with a hole in it.
    var isWorthKeeping: Bool { !urls.isEmpty }
}
