import Foundation

/// What the settings table says about translation, as the types it means rather than as strings.
///
/// `SettingsStore` itself knows only keys and strings; every typed accessor lives beside the type it
/// decodes, which is the rule CLAUDE.md states and the reason that file stopped dragging six
/// subsystems into `SixCore` with it. These two decode a `Locale.Language` and a list of hosts —
/// `Foundation` and nothing else — so they belong on every front rather than in the Apple half,
/// which is where they started and where the Bergamot fronts could not reach them.
extension SettingsStore {
    /// What to translate into. Defaults to the language the interface is in.
    var translationTarget: Locale.Language {
        get {
            guard let stored = self[.translationTarget], !stored.isEmpty else {
                return Locale.current.language
            }
            return Locale.Language(identifier: stored)
        }
        set { self[.translationTarget] = newValue.languageCode?.identifier ?? "" }
    }

    /// Sites translated without being asked.
    var alwaysTranslateHosts: [String] {
        get { decode(.translationHosts) ?? [] }
        set { encode(.translationHosts, newValue, keepingEmpty: false) }
    }
}
