import Foundation
import Testing

@testable import SixCore

/// The Markdown copy, which every front now writes through one type. What is pinned is what a person
/// would notice change: the file's name, and the front matter an editor shows at the top.
struct BookmarkFileTests {
    private let id = UUID(uuidString: "9F73C504-1111-2222-3333-444455556666")!

    @Test func aNameIsTheTitleFoldedAndTheIdsFirstEight() {
        #expect(BookmarkFile.name(for: "Pilaf - Wikipedia", id: id) == "pilaf-wikipedia-9f73c504.md")
        #expect(BookmarkFile.name(for: "Crème brûlée", id: id) == "creme-brulee-9f73c504.md")
        // Cyrillic is alphabetic and stays: the fold removes marks, it does not transliterate.
        #expect(BookmarkFile.name(for: "Плов", id: id) == "плов-9f73c504.md")
        #expect(BookmarkFile.name(for: "", id: id) == "9f73c504.md")
        #expect(BookmarkFile.name(for: "!!!", id: id) == "9f73c504.md")
    }

    @Test func frontMatterNamesTheProfileOnlyWhenThereIsOne() {
        let bookmark = Bookmark(
            id: id, profileID: UUID(), url: URL(string: "https://en.wikipedia.org/wiki/Pilaf")!,
            title: "Pilaf \"rice\"", siteName: "en.wikipedia.org", createdAt: Date(timeIntervalSince1970: 0)
        )
        let named = BookmarkFile.contents(markdown: "Pilaf is a rice dish.", byline: "", bookmark: bookmark, profileName: "Work")
        #expect(named.hasPrefix("---\ntitle: \"Pilaf \\\"rice\\\"\"\nurl: https://en.wikipedia.org/wiki/Pilaf\n"))
        #expect(named.contains("\nprofile: \"Work\"\n"))
        #expect(named.contains("\nsaved: 1970-01-01T00:00:00Z\n"))
        // The body has no heading of its own, so the title is given one.
        #expect(named.hasSuffix("---\n\n# Pilaf \"rice\"\n\nPilaf is a rice dish.\n"))

        let unnamed = BookmarkFile.contents(markdown: "# Pilaf\n\nText", byline: "", bookmark: bookmark, profileName: nil)
        #expect(!unnamed.contains("profile:"))
        #expect(unnamed.hasSuffix("---\n\n# Pilaf\n\nText\n"))
    }
}
