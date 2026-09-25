import Foundation
import GRDB
import SQLiteData
import Testing

@testable import SixCore

/// What the start page and the address field offer out of history.
///
/// The case that started this: a search is stored as the results page's address, percent-encoded,
/// and DuckDuckGo leaves the visit without a title — so a query typed in Russian matched nothing, and
/// "the field doesn't show what I searched before" was true of every Cyrillic search there was.
@MainActor
struct HistorySuggestTests {
    private let profile = UUID()

    /// A database with the visits table and nothing else — never `AppDatabase.open()`, which is the
    /// file a person's browser is using.
    private func store(_ visits: [(String, String)]) throws -> HistoryStore {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE "visits" (
                  "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE,
                  "profileID" TEXT NOT NULL,
                  "url" TEXT NOT NULL,
                  "title" TEXT NOT NULL DEFAULT '',
                  "visitedAt" TEXT NOT NULL
                ) STRICT
                """)
        }
        let history = HistoryStore(database: queue)
        for (url, title) in visits {
            history.record(URL(string: url)!, title: title, in: profile)
        }
        return history
    }

    @Test func aCyrillicSearchIsFoundByWhatWasTyped() throws {
        let history = try store([("https://duckduckgo.com/?q=%D1%85%D1%8D%D0%BB%D0%BE%D1%83", "")])
        #expect(history.suggest("хэл", in: profile, limit: 4).count == 1)
        #expect(history.suggest("Хэлоу", in: profile, limit: 4).count == 1)
        #expect(history.suggest("мир", in: profile, limit: 4).isEmpty)
    }

    /// The engine rewrites its own address as the results load; that is still one search.
    @Test func oneSearchIsOneRowWhateverTheEngineAddedToIt() throws {
        let history = try store([
            ("https://duckduckgo.com/?q=tiling%20hotkeys", ""),
            ("https://example.com/", "Example"),
            ("https://duckduckgo.com/?q=tiling+hotkeys&ia=web", ""),
        ])
        #expect(history.suggest("tiling", in: profile, limit: 4).count == 1)
    }

    @Test func aChatInAFragmentIsNotAPageOfItsOwn() throws {
        let history = try store([
            ("https://web.telegram.org/a/#1910830300", "Telegram"),
            ("https://example.com/", "Example"),
            ("https://web.telegram.org/a/#500931870", "Telegram"),
        ])
        #expect(history.suggest("tele", in: profile, limit: 4).count == 1)
    }

    @Test func aPercentEncodedPathMatchesAsItReads() throws {
        let history = try store([("https://ru.wikipedia.org/wiki/%D0%9F%D0%BB%D0%BE%D0%B2", "")])
        #expect(history.suggest("плов", in: profile, limit: 4).count == 1)
    }

    /// An empty field offers nothing: erasing what was typed is how the list goes away.
    @Test func anEmptyFieldOffersNothing() throws {
        let history = try store([("https://example.com/", "Example")])
        #expect(history.suggest("", in: profile, limit: 5).isEmpty)
    }

    /// A single letter somewhere in the middle of a title is every page there is.
    @Test func oneLetterMatchesOnlyAtTheStart() throws {
        let history = try store([("https://example.com/", "Rate limits"), ("https://github.com/", "GitHub")])
        #expect(history.suggest("g", in: profile, limit: 4).map(\.title) == ["GitHub"])
    }
}
