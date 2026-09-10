import Foundation

/// `SIX_EMBED_SELFTEST=1`: does saving a bookmark on this front make it findable by meaning.
///
/// The question the Mac answers by being used, and the two other fronts cannot, because neither has
/// a bookmarks window to look at yet. So it is asked the way `KeySelfTest` asks about the keyboard —
/// out loud, against the real objects, on a run nobody is watching: save three pages, wait for the
/// embedder, and put four questions to the index.
///
/// **What it is actually testing is the space, not the arithmetic.** Two of the pages say the same
/// thing in Russian and in English and the third says something else entirely, so a working
/// cross-lingual embedder has to put the Russian page above the third one when the question is in
/// English. That is a claim a wrong pooling strategy fails — the trap `MLXEmbedder.pooling`
/// describes, where every sentence lands within a few percent of every other — and which "the
/// vectors are 384 numbers and none of them are NaN" does not catch.
///
/// It writes into a profile id of its own and deletes what it wrote, so running it against the real
/// database leaves it as it was. The vectors go into the same `vec0` table under that partition,
/// which is also worth proving: it is the partitioning that keeps one profile's pages out of
/// another's answers.
nonisolated enum BookmarkSelfTest {
    static var isAsked: Bool {
        ProcessInfo.processInfo.environment["SIX_EMBED_SELFTEST"] == "1"
    }

    /// A page, as the test writes one. Short on purpose: this is measuring whether the model is
    /// loaded and pointing the right way, not how it does on a long document.
    /// A page, as the test writes one — a title, an excerpt and a body, because that is what a real
    /// bookmark has and because `TextChunker` puts the title and the excerpt in a passage of their
    /// own. A title alone is a passage of three words, and a three-word passage in the reader's own
    /// language will out-match a paragraph in another one for reasons that are about length rather
    /// than about meaning.
    private static let pages: [(title: String, excerpt: String, text: String)] = [
        ("Плов", "Рисовое блюдо с мясом и морковью, которое готовят в казане.", """
         Плов готовят в казане: сначала обжаривают мясо, потом закладывают лук и морковь, и только          потом рис.

         Рис заливают водой и томят под крышкой, пока он не впитает бульон. Морковь режут соломкой,          а не трут, иначе она разойдётся в кашу.
         """),
        ("Pilaf", "A rice dish cooked with meat and carrots in a heavy pot.", """
         Pilaf is cooked in a heavy pot: the meat is browned first, then the onion and the carrots,          and the rice goes in last.

         Water is poured over the rice and the whole thing is left to steam until the stock has been          taken up. The carrots are cut into batons rather than grated.
         """),
        ("Reserved domain names", "Domains set aside for use in documentation and examples.", """
         example.com, example.net and example.org are reserved so that a manual can print an address          without pointing at somebody's real site.

         The reservation is made by the IETF, and the same document sets aside .test, .invalid and          .localhost for the same purpose.
         """)
    ]

    /// Four questions, and what a working index has to say to each. The first two are the easy
    /// case — a question in the language of the page. The third and fourth are the interesting one:
    /// asked in one language, answered by the page in the other.
    private static let questions = [
        "как готовят плов",
        "how is pilaf cooked",
        "a dish of rice with meat and carrots",
        "блюдо из риса с мясом и морковью",
        "which domain names are reserved for documentation"
    ]

    /// On the main actor because `BookmarkIndexer` is, and it is where every front's model lives.
    @MainActor
    static func run(_ indexer: BookmarkIndexer, profileID: UUID = UUID()) async -> String {
        var lines = ["profile: \(profileID.uuidString.lowercased())", "index: \(indexer.indexSignature)"]
        var saved: [Bookmark.ID] = []
        defer {
            for id in saved { try? indexer.remove(id) }
        }
        // What the page itself has to say, first. When the embedder is the one that runs in a page,
        // the failures worth telling apart happen before any bookmark is involved — a runtime that
        // will not start, a weights file the document may not read — and they all reach the queue
        // below as the same "index failed" on three rows in a row.
        if let web = indexer.embedder as? WebEmbedder {
            lines.append(await web.diagnostics())
        }
        do {
            for (offset, page) in pages.enumerated() {
                let url = URL(string: "https://example.com/six-embed-selftest/\(offset)")!
                let bookmark = try indexer.save(
                    url: url, title: page.title, excerpt: page.excerpt, siteName: "example.com",
                    text: page.text, profileID: profileID)
                saved.append(bookmark.id)
            }
            lines.append("saved \(saved.count) pages, embedding…")
            let started = ContinuousClock.now
            await indexer.waitForIndexing()
            lines.append("embedded in \(ContinuousClock.now - started)")

            for question in questions {
                let hits = try await indexer.search(question, profileID: profileID, limit: 3)
                let answer = hits.map { String(format: "%@ %.3f", $0.bookmark.displayTitle, $0.score) }
                    .joined(separator: ", ")
                lines.append("  \(question) → \(answer.isEmpty ? "nothing" : answer)")
            }

            // The verdict, and it is deliberately about documents rather than about numbers.
            //
            // Asked in English, the *Russian* page about the same dish has to beat the page about
            // something else; asked in Russian, the English one does. That is the whole claim a
            // cross-lingual embedder makes, and it is the claim a wrong pooling strategy fails —
            // the trap `MLXEmbedder.pooling` describes, where every sentence lands within a few
            // percent of every other. What is deliberately *not* asserted is a margin: E5 favours
            // the language a question is asked in, so the two sides of each pair sit close, and a
            // threshold here would be a number nobody could defend.
            for (question, wanted) in [("a dish of rice with meat and carrots", "Плов"),
                                       ("блюдо из риса с мясом и морковью", "Pilaf")] {
                let hits = try await indexer.search(question, profileID: profileID, limit: 3)
                let other = hits.firstIndex { $0.bookmark.title == wanted }
                let decoy = hits.firstIndex { $0.bookmark.title == "Reserved domain names" }
                switch (other, decoy) {
                case (nil, _):
                    lines.append("cross-lingual: WRONG — «\(wanted)» is not in the answer to \(question)")
                case (let match?, let miss?) where match > miss:
                    lines.append("cross-lingual: WRONG — the page about domain names beat «\(wanted)»")
                default:
                    lines.append("cross-lingual: ok — «\(wanted)» answers \(question)")
                }
            }
        } catch {
            lines.append("failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
