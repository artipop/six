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

/// Which model the vectors are made with.
///
/// The index is bound to it: `Embedding.model` travels with every vector, `Bookmark.embeddingModel`
/// with every row, and `BookmarkStore.indexSignature` compares the two — so this is never a
/// conversion. Changing it re-embeds the library, and the two spaces are never compared.
///
/// The ladder is short on purpose. Both are E5 over the same 250 k vocabulary and the same hundred
/// languages; what the bigger one buys is ranking across languages, and what it costs — download,
/// memory, time — goes up with the hidden size, all three at once.
nonisolated enum EmbeddingModelChoice: String, CaseIterable, Identifiable, Sendable {
    /// `intfloat/multilingual-e5-small`: 118 M parameters, 384 dimensions, ~465 MB on disk.
    case small
    /// `intfloat/multilingual-e5-base`: 278 M parameters, 768 dimensions, ~1.1 GB on disk.
    case base

    var id: String { rawValue }

    /// The Hugging Face repository the weights come from.
    var repository: String {
        switch self {
        case .small: "intfloat/multilingual-e5-small"
        case .base: "intfloat/multilingual-e5-base"
        }
    }

    /// What a vector is stamped with, and what names the `vec0` table it goes into.
    var modelID: String {
        switch self {
        case .small: "multilingual-e5-small"
        case .base: "multilingual-e5-base"
        }
    }

    var dimension: Int {
        switch self {
        case .small: 384
        case .base: 768
        }
    }

    /// What this machine is offered before anybody chooses.
    ///
    /// Memory, and nothing else. The weights are held for as long as six runs, in memory the GPU and
    /// every WebKit process share: `small` holds ~235 MB of it and `base` about twice that, and on a
    /// Mac that has 8 GB — where macOS already sits in its `.warning` pressure band — the second one
    /// is paid for by the pages, which is the wrong thing to pay with. 16 GB is where that stops
    /// being true. Cores are deliberately not part of this: the ranking is what the bigger model
    /// buys, and a slower machine wants it no less.
    static var recommended: EmbeddingModelChoice {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024 ? .base : .small
    }

    /// The name in the picker. The size is in it because the size is the decision.
    var title: String {
        #if os(Linux)
        switch self {
        case .small: "Compact — 465 MB"
        case .base: "Larger — 1.1 GB"
        }
        #else
        switch self {
        case .small: String(localized: "Compact — 465 MB")
        case .base: String(localized: "Larger — 1.1 GB")
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

    /// The model the bookmarks are embedded with — nil until six has decided.
    ///
    /// Nil rather than a default on purpose: the decision is made once, at the first launch that
    /// asks, from `EmbeddingModelChoice.recommended` *and* from whether an index already exists, and
    /// then written down. An update is not allowed to re-embed somebody's library behind their back
    /// because the recommendation moved.
    var embeddingModel: EmbeddingModelChoice? {
        get { self[.embeddingModel].flatMap(EmbeddingModelChoice.init(rawValue:)) }
        set { self[.embeddingModel] = newValue?.rawValue }
    }
}
