import Foundation
import Testing

@testable import SixCore

/// What six sends to an engine, and what it reads back off one of their results pages.
///
/// The reading half is the one with a history behind it. A results page's address is written by the
/// engine's own search box, not by six, and every engine spells a space `+` there — so everything
/// below that involves a two-word query is guarding the line in history that a person actually
/// reads.
struct SearchEngineTests {

    // MARK: Building a search

    @Test func aSearchGoesWhereTheOtherFrontEndsSendIt() {
        #expect(SearchEngine.duckDuckGo.searchURL(for: "pilaf")?.absoluteString == "https://duckduckgo.com/?q=pilaf")
        #expect(SearchEngine.google.searchURL(for: "pilaf")?.absoluteString == "https://www.google.com/search?q=pilaf")
        #expect(SearchEngine.bing.searchURL(for: "pilaf")?.absoluteString == "https://www.bing.com/search?q=pilaf")
    }

    /// Yandex is the one that does not call it `q`, and it is the same name going out and coming
    /// back in.
    @Test func yandexAsksForTextRatherThanQ() {
        #expect(SearchEngine.yandex.searchURL(for: "pilaf")?.absoluteString == "https://yandex.ru/search/?text=pilaf")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.ru/search/?text=pilaf&lr=213")!) == "pilaf")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.ru/search/?q=pilaf")!) == nil)
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
        #expect(SearchEngine.bing.query(from: URL(string: "https://www.bing.com/search?q=apple+tv&form=QBLH")!) == "apple tv")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.ru/search/?text=apple+tv")!) == "apple tv")
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

        let bing = URL(string: "https://www.bing.com/search?q=pilaf&form=QBLH")!
        #expect(SearchEngine.search(from: bing)?.engine == .bing)
        #expect(SearchEngine.google.query(from: bing) == nil)

        let yandex = URL(string: "https://yandex.ru/search/?text=pilaf&lr=213")!
        #expect(SearchEngine.search(from: yandex)?.engine == .yandex)
        #expect(SearchEngine.duckDuckGo.query(from: yandex) == nil)
    }

    /// Google's rule is the path as well as the host: its home page is not a results page. Bing
    /// reads the same way, and Yandex answers from whichever country domain it decided you live
    /// on — including ya.ru, and including the phone's /search/touch/.
    @Test func onlyTheRightHostAndPathCount() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://html.duckduckgo.com/?q=x")!) == "x")
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://notduckduckgo.com/?q=x")!) == nil)
        #expect(SearchEngine.google.query(from: URL(string: "https://www.google.com/?q=x")!) == nil)
        #expect(SearchEngine.google.query(from: URL(string: "https://www.google.com/maps?q=x")!) == nil)
        #expect(SearchEngine.bing.query(from: URL(string: "https://www.bing.com/?q=x")!) == nil)
        #expect(SearchEngine.bing.query(from: URL(string: "https://notbing.com/search?q=x")!) == nil)
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.com.tr/search/?text=x")!) == "x")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://ya.ru/search/?text=x")!) == "x")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.ru/search/touch/?text=x")!) == "x")
        #expect(SearchEngine.yandex.query(from: URL(string: "https://yandex.ru/maps/?text=x")!) == nil)
        #expect(SearchEngine.yandex.query(from: URL(string: "https://notyandex.ru/search/?text=x")!) == nil)
    }

    @Test func aPageWithNoQueryIsNotOne() {
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/")!) == nil)
        #expect(SearchEngine.duckDuckGo.query(from: URL(string: "https://duckduckgo.com/?q=")!) == nil)
        #expect(SearchEngine.search(from: URL(string: "https://example.com/?q=x")!) == nil)
    }
}
