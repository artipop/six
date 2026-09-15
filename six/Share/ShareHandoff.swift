import Foundation

/// The wire between six and its share extension — the one file both of them compile.
///
/// The extension is a separate, sandboxed process, and a sandbox leaves it two ways of talking to the
/// app that need no team, no App Group and no provisioning profile: opening a URL, and reading a file
/// the entitlements name. So each direction takes one of them. The app writes where its windows are
/// (`ShareTargets`, `share-targets.json` beside `state.json`) so that the sheet in the other app can
/// offer a workspace by name; the sheet answers with a `ShareRequest`, which is a `six-share://`
/// address handed to the app that contains the extension.
///
/// Both halves are versioned in the loosest way that works: a field that is missing decodes as
/// nothing, and a request the app does not understand is dropped rather than guessed at. The two are
/// always built together, from one bundle, so the version skew this guards against is a stale file
/// from a launch of an older build — not a stale extension.
nonisolated struct ShareRequest: Equatable, Sendable {
    nonisolated enum Action: String, Sendable, CaseIterable {
        /// Open the address — or search for the text — in a window on the chosen workspace.
        case open
        /// Open it in the private window instead: nothing about it is recorded.
        case openPrivate = "private"
        /// Save it to the chosen profile's bookmarks without opening anything.
        case bookmark
    }

    var action: Action
    /// What was shared: an address (a web page or a file six can show), or text to search for.
    var url: URL?
    var text: String?
    /// The title the sharing app gave it, if any — the bookmark's name until the page is read.
    var title: String?
    var profileID: UUID?
    /// A workspace by id, not by row: the rail can change between the sheet opening and the click.
    var workspaceID: UUID?

    /// The two schemes the handoff arrives on. Two, for the same reason there are two web schemes in
    /// `Info.plist`: a development build must not answer for the installed one.
    static let schemes: Set<String> = ["six-share", "six-dev-share"]

    func address(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action.rawValue
        var items: [URLQueryItem] = []
        if let url { items.append(URLQueryItem(name: "url", value: url.absoluteString)) }
        if let text, !text.isEmpty { items.append(URLQueryItem(name: "text", value: text)) }
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
        if let profileID { items.append(URLQueryItem(name: "profile", value: profileID.uuidString)) }
        if let workspaceID { items.append(URLQueryItem(name: "workspace", value: workspaceID.uuidString)) }
        components.queryItems = items
        return components.url
    }

    init(action: Action, url: URL? = nil, text: String? = nil, title: String? = nil,
         profileID: UUID? = nil, workspaceID: UUID? = nil) {
        self.action = action
        self.url = url
        self.text = text
        self.title = title
        self.profileID = profileID
        self.workspaceID = workspaceID
    }

    /// Nil for anything that is not a handoff, or is one with nothing in it.
    init?(address: URL) {
        guard let scheme = address.scheme?.lowercased(), Self.schemes.contains(scheme),
              let host = address.host(), let action = Action(rawValue: host),
              let components = URLComponents(url: address, resolvingAgainstBaseURL: false)
        else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(action: action,
                  url: value("url").flatMap(URL.init(string:)),
                  text: value("text"),
                  title: value("title"),
                  profileID: value("profile").flatMap(UUID.init(uuidString:)),
                  workspaceID: value("workspace").flatMap(UUID.init(uuidString:)))
        guard url != nil || text != nil else { return nil }
    }
}

/// Where a shared page could go: every profile that keeps anything, and the rows of its rail.
///
/// Written by the app, read by the extension, never the other way. What is in it is what the rail
/// already shows on screen — names, and the titles of a row's first few windows so that an unnamed
/// workspace can still be told from the next one — and a private profile is left out of it entirely,
/// the way it is left out of the snapshot.
nonisolated struct ShareTargets: Codable, Sendable, Equatable {
    static let fileName = "share-targets.json"

    nonisolated struct Workspace: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        /// Empty for an unnamed one; the sheet says "Workspace N" then, as the rail does.
        var name: String
        var windowCount: Int
        /// The first few windows' titles, left to right.
        var pages: [String]
        var isFocused: Bool
    }

    nonisolated struct Profile: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var colorHex: String
        var isSelected: Bool
        /// Top to bottom. The last one is the empty row a rail always keeps below the others.
        var workspaces: [Workspace]
    }

    var version = 1
    var profiles: [Profile]
}
