import Foundation
import GRDB

@testable internal import SixCore

/// Saved pages on Windows, over the same tables the Mac writes — and, unlike the Linux front's
/// first version of this, with the vectors in them.
///
/// Almost nothing is here, and that is the point: `BookmarkIndexer` in `SixCore` holds the row, the
/// passages, the embedding queue and the search, because a bookmark saved here has to be one a Mac
/// can read, re-embed and rank. What this file adds is the two things that cannot live there — the
/// off-screen page the embedder runs in, which only a front can make, and the decision of which
/// model to run, which comes out of the settings table.
extension RailModel {
    /// Hands the model an off-screen page to embed in.
    ///
    /// Two closures rather than a protocol, and that is deliberate. `PageSandbox` is `SixCore`'s and
    /// internal, so it cannot appear in a `public` signature here; a second public protocol in this
    /// module would be a type whose only job is to be re-implemented on the other side of a seam
    /// three lines wide. `SixUI` already owns a `PageSandbox`; these are its two methods.
    ///
    /// Called once, after there is a window — a web view needs a parent, and on Windows a window
    /// belongs to the thread that made it.
    public func attachSandbox(
        open: @escaping @MainActor (URL) async throws -> Void,
        call: @escaping @MainActor (String, String) async throws -> String
    ) {
        guard let bookmarks else { return }
        let sandbox = ClosureSandbox(open: open, call: call)
        let embedder = WebEmbedder(choice: bookmarks.choice, store: EmbeddingStore(), sandbox: sandbox)
        embedder.setStatusHandler { status in
            guard !status.isEmpty else { return }
            Log.info(.bookmarks, "embedder: \(status)")
        }
        bookmarks.use(embedder)
        runSelfTestIfAsked(bookmarks)
    }

    /// `SIX_EMBED_SELFTEST=1`: save three pages, embed them, and ask the index four questions.
    /// Detached, because it takes as long as a model download and the window should come up anyway.
    func runSelfTestIfAsked(_ indexer: BookmarkIndexer) {
        guard BookmarkSelfTest.isAsked else { return }
        Task { @MainActor in
            // Through the log rather than `print`, and that is not a style choice: a `print`
            // from a process whose stdout is a file goes into a buffer nobody flushes, so the
            // whole report sits there until six exits — which, for a run that ends by being
            // killed, is never. The log writes and flushes, and still puts it on stderr when
            // a person is watching.
            // The report is built first because `Log.info` takes an autoclosure, and an
            // `await` inside one is not a thing the compiler will hold still for.
            let report = await BookmarkSelfTest.run(indexer)
            Log.info(.bookmarks, "bookmark embedding self-test\n" + report)
        }
    }

    /// Saves the page a column is on, or unsaves it if it is already there. The title and the
    /// address are what this front knows without reading the page again; `text` is the readable body
    /// once there is an extractor to produce one, and until then the title and the host are a
    /// passage of their own and still searchable.
    @discardableResult
    public func toggleBookmark(url: URL, title: String, text: String = "") -> Bool {
        guard let bookmarks else { return false }
        do {
            if let existing = bookmarks.bookmark(for: url, in: activeProfile.id) {
                try bookmarks.remove(existing.id)
                return false
            }
            try bookmarks.save(url: url, title: title, text: text, profileID: activeProfile.id)
            return true
        } catch {
            Log.error(.bookmarks, "could not save \(url): \(error)")
            return false
        }
    }

    /// Whether this address is saved, so a star can say so.
    public func isBookmarked(_ url: URL) -> Bool {
        bookmarks?.bookmark(for: url, in: activeProfile.id) != nil
    }

    // MARK: The star in the bar

    /// The page the bar is describing, as something a bookmark can be made of.
    ///
    /// `nil` when there is no focused column, or when its address is not one — the rail opens a
    /// column before anything has loaded, and a row keyed by a string that is not a URL is a row
    /// nothing can ever find again.
    private var focusedPage: (url: URL, title: String)? {
        guard let focused = columns.first(where: \.isFocused),
              let url = URL(string: url(for: focused.id)), url.scheme != nil
        else { return nil }
        return (url, focused.title)
    }

    /// Whether the star has anything to act on. False on a private profile, which is the Mac's rule
    /// and the Linux front's: a bookmark is a record like any other, and a private profile keeps
    /// none.
    public var canBookmarkFocusedPage: Bool {
        bookmarks != nil && !activeProfile.isPrivate && focusedPage != nil
    }

    /// Whether the page the bar is describing is saved, so the star knows which way to point.
    public var isFocusedPageBookmarked: Bool {
        guard !activeProfile.isPrivate, let page = focusedPage else { return false }
        return isBookmarked(page.url)
    }

    /// The star's click. Saved is saved as soon as the row exists — the embedding that follows is
    /// the index's business, and a star that waited for it would spend a second looking broken.
    public func toggleFocusedPageBookmark() {
        guard canBookmarkFocusedPage, let page = focusedPage else { return }
        toggleBookmark(url: page.url, title: page.title)
    }

    /// What a search of the saved pages answers: enough to draw a row, and nothing else.
    public struct BookmarkHitRow: Identifiable, Sendable {
        public let id: UUID
        public var url: URL
        public var title: String
        public var snippet: String
        public var score: Double
    }

    /// Bookmarks near a question by meaning, this profile's only.
    public func searchBookmarks(_ query: String, limit: Int = 10) async -> [BookmarkHitRow] {
        guard let bookmarks else { return [] }
        do {
            let hits = try await bookmarks.search(query, profileID: activeProfile.id, limit: limit)
            return hits.map {
                BookmarkHitRow(id: $0.bookmark.id, url: $0.bookmark.url,
                               title: $0.bookmark.displayTitle, snippet: $0.snippet, score: $0.score)
            }
        } catch {
            Log.error(.bookmarks, "search failed: \(error)")
            return []
        }
    }
}

/// `PageSandbox`, made out of the two closures `SixUI` handed over.
@MainActor
private final class ClosureSandbox: PageSandbox {
    private let openPage: @MainActor (URL) async throws -> Void
    private let callPage: @MainActor (String, String) async throws -> String

    init(open: @escaping @MainActor (URL) async throws -> Void,
         call: @escaping @MainActor (String, String) async throws -> String) {
        openPage = open
        callPage = call
    }

    func open(_ url: URL) async throws { try await openPage(url) }
    func call(_ body: String, input: String) async throws -> String { try await callPage(body, input) }
}
