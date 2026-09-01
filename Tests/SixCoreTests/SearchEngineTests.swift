import Foundation
import Testing

@testable import SixCore

/// What six sends to an engine, and what it reads back off one of their results pages.
///
/// The reading half is the one with a history behind it. A results page's address is written by the
/// engine's own search box, not by six, and both engines spell a space `+` there — so everything
/// below that involves a two-word query is guarding the line in history that a person actually
/// reads.
struct SearchEngineTests {

    // MARK: Building a search

    @Test func aSearchGoesWhereTheOtherFrontEndsSendIt() {
        #expect(SearchEngine.duckDuckGo.searchURL(for: "pilaf")?.absoluteString == "https://duckduckgo.com/?q=pilaf")
        #expect(SearchEngine.google.searchURL(for: "pilaf")?.absoluteString == "https://www.google.com/search?q=pilaf")
    }

    /// `URLComponents` writes `%20`, and Android goes out of its way to match it: the same search
    /// recorded two ways is two rows in one history.
    @Test func aSpaceSixWritesIsPercentTwenty() {
        let url = SearchEngine.duckDuckGo.searchURL(for: "apple tv")
        #expect(url?.absoluteString == "https://duckduckgo.com/?q=apple%20tv")
    }

    // MARK: Reading one back

    @Test func aQuerySixWroteSurvivesTheRoundTrip() {
        for engine in SearchEngine.allCases {
            let query = "плов рецепт"
            let url = engine.searchURL(for: query)!
            #expect(engine.query(from: url) == query)
        }
    }

    /// The bug this file was written for: the engines' own search boxes write `слово+раз`, and
    /// history showed the `+`.
    @Test func aSpaceTheEngineWroteIsAPlus() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/?q=%D1%81%D0%BB%D0%BE%D0%B2%D0%BE+%D1%80%D0%B0%D0%B7")!) == "слово раз")
        #expect(SearchEngine.google.query(from: URL(string: "https://www.google.com/search?q=apple+tv&hl=en")!) == "apple tv")
        #expect(SearchEngine.search(from: URL(string: "https://duckduckgo.com/?q=apple+tv&ia=web")!)?.query == "apple tv")
    }

    /// And a plus that was searched *for* arrives as `%2B`, which is why the substitution happens
    /// before the decode rather than after it.
    @Test func aPlusThatWasTypedStaysAPlus() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/?q=c%2B%2B+tutorial")!) == "c++ tutorial")
    }

    // MARK: Recognising a results page

    @Test func aResultsPageIsRecognisedByItsOwnEngineOnly() {
        let duck = URL(string: "https://duckduckgo.com/?q=pilaf&ia=web")!
        #expect(SearchEngine.duckDuckGo.query(from: duck) == "pilaf")
        #expect(SearchEngine.google.query(from: duck) == nil)

        let google = URL(string: "https://www.google.com/search?q=pilaf&hl=en")!
        #expect(SearchEngine.google.query(from: google) == "pilaf")
        #expect(SearchEngine.duckDuckGo.query(from: google) == nil)

        let found = SearchEngine.search(from: google)
        #expect(found?.engine == .google)
        #expect(found?.query == "pilaf")
    }

    /// Google's rule is the path as well as the host: its home page is not a results page.
    @Test func onlyTheRightHostAndPathCount() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://html.duckduckgo.com/?q=x")!) == "x")
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://notduckduckgo.com/?q=x")!) == nil)
        #expect(SearchEngine.google.query(from: URL(string: "https://www.google.com/?q=x")!) == nil)
        #expect(SearchEngine.google.query(from: URL(string: "https://www.google.com/maps?q=x")!) == nil)
    }

    @Test func aPageWithNoQueryIsNotOne() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/")!) == nil)
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/?q=")!) == nil)
        #expect(SearchEngine.search(from: URL(string: "https://example.com/?q=x")!) == nil)
    }
}
