import Foundation

// Compiled away on Apple, deliberately: the Mac and the phone keep the strip in `state.json`
// (`AppStateSnapshot`), and the synchronized `six/` folder would otherwise hand this to both app
// targets. Off Apple it is `SixCore`'s, listed in the root manifest.
#if os(Linux) || os(Windows)

/// The strip as it was left, so a relaunch opens where the last one closed — on the fronts that are
/// not the Mac.
///
/// In the `settings` table rather than a file beside it. The Mac keeps this in `state.json`, and
/// that file is fine there — but a front that has no snapshot machinery yet gets the durable thing
/// for free by using the database that is already open, already migrated, and already the place
/// every other preference lives.
///
/// What is stored is `TilingStrip` itself — the same `Codable` type the Mac writes, unchanged — plus
/// the address each column was on. The layout is the shape; the addresses are what makes the shape
/// mean something after a restart.
///
/// Linux wrote it first and Windows reads it now, which is why it is here rather than in either
/// front: both write the same key, and a row one of them wrote is a row the other has to be able to
/// read — they never share a database, but the day one is copied from a machine to another is not
/// the day to find out the two `Codable`s had drifted.
nonisolated struct StripState: Codable {
    var strips: [String: TilingStrip] = [:]
    var urls: [String: String] = [:]
    var titles: [String: String] = [:]
    /// The profile on screen. Linux keeps it here; Windows reads `profile.selected` instead, because
    /// that front has a profiles table and two records of one fact are two chances to disagree.
    var activeProfile: String = ""

    @MainActor
    static func load(from settings: ConfigurationStore) -> StripState? {
        guard let json = settings[.stripState], let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StripState.self, from: data)
    }

    @MainActor
    func save(to settings: ConfigurationStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        settings[.stripState] = String(decoding: data, as: UTF8.self)
    }

    /// A column with no address is a column that cannot be rebuilt, so it is not worth restoring —
    /// the strip would come back with a hole in it.
    var isWorthKeeping: Bool { !urls.isEmpty }
}

#endif
