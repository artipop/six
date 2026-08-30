import Foundation
import SQLiteData

/// A saved page. The row is the record; the readable copy is a Markdown file in the profile's
/// `Bookmarks` folder (`fileName`), and the searchable form is `bookmark_chunks` + the vectors.
@Table("bookmarks")
nonisolated struct Bookmark: Identifiable, Sendable, Hashable {
    let id: UUID
    var profileID: UUID
    var url: URL
    var title = ""
    /// The page's own description, or the first paragraph.
    var excerpt = ""
    var siteName = ""
    var imageURL: URL?
    /// Name of the Markdown file inside the profile's bookmarks folder.
    var fileName = ""
    /// BCP-47 tag as the page declared it (or as detected), e.g. `ru`, `en`.
    var language = ""
    /// Length of the readable text — a hint of how much was saved.
    var characterCount = 0
    var createdAt: Date
    /// When the chunks were embedded; nil until the index has caught up (or `indexError` says why not).
    var indexedAt: Date?
    /// The embedder and index version the vectors were made with; a change means re-embedding.
    var embeddingModel = ""
    var indexError: String?
    /// When the page was last re-read from the site (nil: never since it was saved).
    var refreshedAt: Date?
    /// SHA-256 of the readable text, so a refresh that finds the same page changes nothing.
    var contentHash = ""
    /// Why the last refresh didn't happen — the site was down, the page has no text now.
    var refreshError: String?

    var lastReadAt: Date { refreshedAt ?? createdAt }

    var displayTitle: String { title.isEmpty ? url.absoluteString : title }
    var displayDetail: String { siteName.isEmpty ? (url.host() ?? url.absoluteString) : siteName }
}

/// One passage of a bookmark's text, in reading order. Chunk 0 is the title and excerpt, so a
/// search for what a page is about finds it even when the body is long.
@Table("bookmark_chunks")
nonisolated struct BookmarkChunk: Identifiable, Sendable {
    let id: UUID
    var bookmarkID: UUID
    var ord: Int
    var text: String
}

/// Which bookmarks a search or an assistant sees: the current profile's, or everyone's.
nonisolated enum BookmarkScope: String, CaseIterable, Identifiable, Sendable {
    case profile
    case all

    var id: String { rawValue }

    var title: String {
        #if os(Linux)
        // `String(localized:)` and the strings catalog behind it are Apple Foundation's; a GTK front
        // localises through gettext, so these are the keys and it translates them itself.
        switch self {
        case .profile: "This Profile"
        case .all: "All Profiles"
        }
        #else
        switch self {
        case .profile: String(localized: "This Profile")
        case .all: String(localized: "All Profiles")
        }
        #endif
    }
}

/// A search result: the bookmark, how well it matched, and the passage that matched.
nonisolated struct BookmarkHit: Identifiable, Sendable {
    var bookmark: Bookmark
    /// 0…1, higher is better. Vector hits are `1 - cosine distance / 2`; text matches are fixed.
    var score: Double
    var snippet: String

    var id: Bookmark.ID { bookmark.id }
}

// MARK: - Settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// What the assistant and the agents search: this profile's bookmarks, or every profile's.
    var bookmarkScope: BookmarkScope {
        get { BookmarkScope(rawValue: self[.bookmarkScope] ?? "") ?? .profile }
        set { self[.bookmarkScope] = newValue.rawValue }
    }
}
