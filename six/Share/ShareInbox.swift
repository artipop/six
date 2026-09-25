import Foundation

/// The app's half of the share extension: what the sheet in another app asked for, done.
///
/// The request names a profile and a workspace by id, and either can be gone by the time it lands —
/// the sheet read a file written a moment ago, and the row has moved since. Neither is a reason to
/// drop what was shared: an unknown profile is the one on screen, an unknown row is the focused one.
extension BrowserState {
    func receive(_ request: ShareRequest) {
        let named = request.profileID.flatMap { id in profiles.first { $0.id == id && !$0.isPrivate } }
        let profile = named ?? profiles.first { $0.id == selectedProfileID && !$0.isPrivate }
            ?? profiles.first { !$0.isPrivate } ?? selectedProfile
        let destination = request.url ?? request.text.flatMap(URL.fromUserInput)
        Log.info(.browser, "shared in: \(request.action.rawValue) \(destination?.absoluteString ?? "nothing")")
        switch request.action {
        case .open:
            guard let destination else { return }
            let row = request.workspaceID.flatMap { id in
                layout.strip(for: profile.id).workspaces.firstIndex { $0.id == id }
            }
            newTab(url: destination, in: profile.id, workspace: row, activate: true)
        case .openPrivate:
            guard let destination else { return }
            newPrivateWindow(url: destination)
        case .bookmark:
            // Only what a bookmark can be made of: a page on the web. Text and files are offered no
            // bookmark in the sheet, so one arriving here was not asked for by a person.
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let bookmarks else { return }
            let title = request.title ?? ""
            Task {
                do {
                    let saved = try await bookmarks.add(url: url, title: title, in: profile.id)
                    Log.info(.bookmarks, "shared in and saved: \(saved.displayTitle)")
                } catch {
                    Log.error(.bookmarks, "shared in, not saved (\(url.absoluteString)): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Where the sheet may send a page: the row as it stands, minus anything private.
    var shareTargets: ShareTargets {
        ShareTargets(profiles: profiles.filter { !$0.isPrivate }.map { profile in
            let strip = layout.strip(for: profile.id)
            let workspaces = strip.workspaces.enumerated().map { index, workspace in
                let ids = workspace.columns.flatMap(\.tabIDs)
                return ShareTargets.Workspace(
                    id: workspace.id,
                    name: workspace.name,
                    windowCount: ids.count,
                    pages: ids.prefix(3).compactMap { tab($0)?.title }.filter { !$0.isEmpty },
                    isFocused: index == strip.focus)
            }
            return ShareTargets.Profile(id: profile.id, name: profile.name, colorHex: profile.colorHex,
                                        isSelected: profile.id == selectedProfileID, workspaces: workspaces)
        })
    }
}

extension BrowserTab {
    /// What the share button hands to the system: a page's own address. Not a start page, not one of
    /// six's `six://` pages and not a document — none of those is an address anybody else can open.
    var shareableURL: URL? {
        guard !isDocument, !showsStartPage, let url = currentURL,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The name the share sheet shows for it, which is also the subject a mail gets.
    var shareTitle: String {
        title.isEmpty ? (currentURL?.host() ?? currentURL?.absoluteString ?? "") : title
    }
}

#if os(macOS)
/// The file is rewritten the way the snapshot is — debounced, off the main thread, atomically — by
/// the same machinery, so that the sheet never reads half of one.
nonisolated extension ShareTargets: VersionedSnapshot {
    static var currentVersion: Int { 1 }
}
#endif
