import AppKit
import SwiftUI

/// ⌘⌥B: the bookmarks — this profile's or everyone's — searched by meaning. Double-click opens the
/// page in a new window; the file behind a bookmark can be shown in the Finder; ⌫ removes it.
struct BookmarksView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [BookmarkHit] = []
    @State private var searching = false
    @State private var selection: Bookmark.ID?
    @FocusState private var searchFocused: Bool

    private var profile: Profile { browser.selectedProfile }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(profile.color).frame(width: 10, height: 10)
                Text(settings.bookmarkScope == .all ? "All Bookmarks" : "\(profile.name) Bookmarks").font(.headline)
                Picker("Scope", selection: $settings.bookmarkScope) {
                    ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("What the list, the assistant and the agents see")
                Spacer()
                TextField("Search by meaning", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($searchFocused)
                    .onSubmit(openSelectedOrFirst)
                if searching { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if hits.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No Bookmarks" : "No Matches", systemImage: "bookmark")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(hits) { hit in
                        BookmarkRow(hit: hit, showsProfile: settings.bookmarkScope == .all, busy: bookmarks.indexing.contains(hit.id) || bookmarks.refreshing.contains(hit.id))
                            .tag(hit.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(hit.bookmark) }
                            .contextMenu {
                                Button("Open in New Window") { open(hit.bookmark) }
                                Button("Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hit.bookmark.url.absoluteString, forType: .string)
                                }
                                Button("Refresh Now") { Task { await bookmarks.refresh(hit.id) } }
                                if let file = bookmarks.fileURL(of: hit.bookmark) {
                                    Button("Show File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                }
                                Divider()
                                Button("Remove", role: .destructive) { bookmarks.remove(hit.id) }
                            }
                    }
                }
                .onDeleteCommand { if let selection { bookmarks.remove(selection) } }
                .onKeyPress(.return) { openSelectedOrFirst(); return .handled }
            }
            Divider()
            HStack {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bookmarks.folder(for: profile)]) }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .onAppear { searchFocused = true }
        .task(id: SearchKey(query: query, scope: settings.bookmarkScope, profile: profile.id, revision: bookmarks.revision)) {
            await search()
        }
    }

    private struct SearchKey: Equatable {
        var query: String
        var scope: BookmarkScope
        var profile: Profile.ID
        var revision: Int
    }

    private var footer: String {
        let pending = hits.filter { $0.bookmark.indexedAt == nil && $0.bookmark.indexError == nil }.count
        var text = "\(hits.count) bookmarks"
        if pending > 0 { text += " · \(pending) indexing" }
        text += " · \(bookmarks.embedder.modelID), on device"
        if !bookmarks.embedderStatus.isEmpty, bookmarks.embedderStatus != "ready" { text += " · \(bookmarks.embedderStatus)" }
        return text
    }

    private func search() async {
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(250)) // let typing settle before embedding the query
            guard !Task.isCancelled else { return }
        }
        searching = true
        defer { searching = false }
        let result = await bookmarks.search(query, in: settings.bookmarkScope, profileID: profile.id, limit: 200)
        guard !Task.isCancelled else { return }
        hits = result
    }

    /// Relative to the screen, like the history sheet.
    private var sheetSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: (screen.width * 0.42).rounded(), height: (screen.height * 0.62).rounded())
    }

    private func openSelectedOrFirst() {
        if let selection, let hit = hits.first(where: { $0.id == selection }) {
            open(hit.bookmark)
        } else if let first = hits.first {
            open(first.bookmark)
        }
    }

    private func open(_ bookmark: Bookmark) {
        browser.newTab(url: bookmark.url, in: bookmark.profileID)
        dismiss()
    }
}

private struct BookmarkRow: View {
    let hit: BookmarkHit
    let showsProfile: Bool
    let busy: Bool
    @Environment(BrowserState.self) private var browser

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if showsProfile, let profile = browser.profiles.first(where: { $0.id == hit.bookmark.profileID }) {
                        Circle().fill(profile.color).frame(width: 8, height: 8).help(profile.name)
                    }
                    Text(hit.bookmark.displayTitle).lineLimit(1)
                }
                Text(hit.bookmark.displayDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(hit.bookmark.createdAt, style: .date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(hit.bookmark.refreshedAt.map { "Re-read \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Saved; not re-read yet")
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let error = hit.bookmark.indexError, hit.bookmark.indexedAt == nil {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
                } else if let error = hit.bookmark.refreshError {
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange).help("Last refresh failed: \(error)")
                } else if hit.score > 0 {
                    Text(String(format: "%.0f%%", hit.score * 100)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

extension FocusedValues {
    @Entry var showBookmarks: FocusAddressBarAction?
}
