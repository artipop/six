import Foundation

/// A filter list: an address to fetch rules from, in the AdGuard/EasyList syntax every blocker
/// speaks, and whether the user wants it. Lists someone adds by URL are the same type as the
/// built-in ones — `isBuiltIn` only says whether it can be removed.
///
/// The catalogue points at AdGuard's *Safari* builds of its filters (`/extension/safari/`), which
/// are the same lists with the modifiers WebKit cannot express already dropped: converting them
/// leaves far fewer rules on the floor than converting the browser-extension builds would.
nonisolated struct FilterList: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var title: String
    /// What the list is for, in one line — the panel shows it under the title.
    var detail: String
    var source: URL
    var isBuiltIn: Bool
    var isEnabled: Bool

    init(id: String, title: String, detail: String = "", source: URL, isBuiltIn: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.source = source
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }

    private static func adGuard(_ number: Int) -> URL {
        URL(string: "https://filters.adtidy.org/extension/safari/filters/\(number).txt")!
    }

    /// The built-in catalogue. Ads and tracking are on out of the box; annoyances (cookie notices,
    /// newsletter overlays) are opinionated enough to be a choice. The language list follows the
    /// system's preferred languages — a Russian-speaking Mac gets the Russian list, which the
    /// English-first lists do not cover.
    static func catalogue(languages: [String] = Locale.preferredLanguages) -> [FilterList] {
        let prefersRussian = languages.contains { $0.hasPrefix("ru") }
        return [
            FilterList(id: "adguard-base", title: "AdGuard Base",
                       detail: String(localized: "Ads on most of the web"), source: adGuard(2), isBuiltIn: true),
            FilterList(id: "adguard-privacy", title: "AdGuard Tracking Protection",
                       detail: String(localized: "Trackers, analytics and beacons"), source: adGuard(3), isBuiltIn: true),
            FilterList(id: "adguard-annoyances", title: "AdGuard Annoyances",
                       detail: String(localized: "Cookie notices, in-page overlays, widgets"), source: adGuard(14),
                       isBuiltIn: true, isEnabled: false),
            FilterList(id: "adguard-russian", title: "AdGuard Russian",
                       detail: String(localized: "Ads on Russian-language sites"), source: adGuard(1),
                       isBuiltIn: true, isEnabled: prefersRussian),
        ]
    }

    /// The stored set, healed against the catalogue: a list added to (or dropped from) a later
    /// version of six appears (or disappears) without touching what the user chose about the rest.
    static func merge(stored: [FilterList], catalogue: [FilterList] = FilterList.catalogue()) -> [FilterList] {
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let builtInIDs = Set(catalogue.map(\.id))
        var merged: [FilterList] = catalogue.map { built in
            guard var kept = byID[built.id] else { return built }
            // The address and the words are ours; only the checkbox is the user's.
            kept.title = built.title
            kept.detail = built.detail
            kept.source = built.source
            kept.isBuiltIn = true
            return kept
        }
        // Lists the user added by URL keep their order after the catalogue.
        merged += stored.filter { !builtInIDs.contains($0.id) }.map { added in
            var list = added
            list.isBuiltIn = false
            return list
        }
        return merged
    }
}
