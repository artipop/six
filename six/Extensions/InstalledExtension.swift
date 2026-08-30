import Foundation

/// An extension six has unpacked into its own folder, as it is remembered between launches. The
/// folder is the truth about what the extension *is*; this is what the user decided about it.
nonisolated struct InstalledExtension: Identifiable, Codable, Sendable, Hashable {
    /// Also the folder name under `Application Support/org.deffun.six/Extensions/`, and the context's
    /// `uniqueIdentifier` — which is what makes an extension's storage survive a relaunch.
    var id: String
    var name: String
    var version: String
    var isEnabled: Bool
    /// Where it came from, for the panel: a folder someone pointed at, or an archive's file name.
    var origin: String
    var installedAt: Date

    var folder: URL {
        InstalledExtension.folder.appending(path: id, directoryHint: .isDirectory)
    }

    static let folder: URL = {
        AppSupport.folder("Extensions")
    }()
}

/// What six can tell about an extension **before** loading it, from the manifest alone — so that
/// installing one is not a matter of trying it and wondering.
///
/// The line it draws is the one measured in [docs/extensions.md](../../docs/extensions.md): a content
/// script runs, but it cannot talk to its extension, and its extension cannot inject anything new
/// into a page. Anything built around that conversation is broken here, and says so before it is
/// installed rather than after.
nonisolated struct ExtensionCompatibility: Sendable, Hashable, Codable {
    enum Verdict: String, Sendable, Codable {
        /// Nothing it asks for depends on reaching into a page.
        case full
        /// Its content scripts will run, but it cannot message them or inject more.
        case partial
        /// What it is made of is exactly what does not work.
        case unsupported
    }

    var verdict: Verdict
    /// One line for the install dialog and the row in the panel.
    var summary: String
    /// The specifics, listed under it.
    var details: [String]

    var symbol: String {
        switch verdict {
        case .full: "checkmark.circle"
        case .partial: "exclamationmark.triangle"
        case .unsupported: "xmark.octagon"
        }
    }
}

// MARK: - Settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// The extensions six has unpacked, and what the user decided about each.
    var installedExtensions: [InstalledExtension] {
        get { decode(.installedExtensions) ?? [] }
        set { encode(.installedExtensions, newValue) }
    }
}
