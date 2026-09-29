import Foundation
import Testing

@testable import SavoiaCore

/// The verdicts `TabSorter` acts on, with vectors laid along axes so a cosine is known by eye.
struct TabTopicsTests {
    private func tab(_ vector: [Float], host: String = "", title: String = "", opener: UUID? = nil) -> TabTopics.Tab {
        TabTopics.Tab(id: UUID(), vector: vector, host: host, title: title, opener: opener)
    }

    private func group(_ members: [TabTopics.Tab], name: [Float]? = nil) -> TabTopics.Group {
        TabTopics.Group(id: UUID(), name: name, members: members)
    }

    @Test func aTabCloseToOneGroupJoinsIt() {
        let swift = group([tab([1, 0, 0]), tab([0.95, 0.05, 0])])
        let food = group([tab([0, 1, 0])])
        let verdict = TabTopics.classify(tab([0.98, 0.1, 0]), among: [swift, food], background: 0.1)
        #expect(verdict == .group(swift.id))
    }

    @Test func aTabAboutNeitherStaysWhereItIs() {
        let swift = group([tab([1, 0, 0])])
        let food = group([tab([0, 1, 0])])
        #expect(TabTopics.classify(tab([0, 0, 1]), among: [swift, food], background: 0) == .none)
    }

    /// With one group there is no runner-up, and the tab's usual similarity to everything stands in.
    @Test func aLoneGroupHasToBeatWhatTheTabIsUsuallyLike() {
        let swift = group([tab([1, 0, 0])])
        let near = tab([0.9, 0.44, 0])
        #expect(TabTopics.classify(near, among: [swift], background: 0.5) == .group(swift.id))
        #expect(TabTopics.classify(near, among: [swift], background: 0.89) == .none)
    }

    /// Closer to a tab with no group than to the group: the start of another group, not this one.
    @Test func aGroupHasToBeatTheNearestLooseTab() {
        let tech = group([tab([1, 0, 0])])
        let soup = tab([0.5, 0.86, 0])
        #expect(TabTopics.classify(soup, among: [tech], background: 0) == .group(tech.id))
        #expect(TabTopics.classify(soup, among: [tech], background: 0, loose: 0.9) == .none)
    }

    /// A little ahead of the rest with nothing loose nearby is noise at e5's spread, and stays put.
    @Test func aTabOnlyALittleAheadStaysWhereItIs() {
        let dinner = group([tab([1, 0, 0])])
        #expect(TabTopics.classify(tab([0.9, 0.44, 0]), among: [dinner], background: 0.87) == .none)
    }

    /// Another dish arriving alongside, about as near as the group, no longer makes a second group of them.
    @Test func aLooseTabAsNearAsTheGroupDoesNotPullItAway() {
        let dinner = group([tab([1, 0, 0])])
        let dish = tab([0.9, 0.44, 0])
        guard case .near(let id, let weight) = TabTopics.classify(dish, among: [dinner], background: 0.5, loose: 0.91) else {
            Issue.record("expected near")
            return
        }
        #expect(id == dinner.id)
        #expect(weight == 0.5)
    }

    @Test func aTabHalfwayStandsBetweenTheTwo() {
        let sport = group([tab([1, 0, 0])])
        let food = group([tab([0, 1, 0])])
        let verdict = TabTopics.classify(tab([1, 1, 0]), among: [sport, food], background: 0)
        guard case .between(let from, let to, let weight) = verdict else {
            Issue.record("expected between, got \(verdict)")
            return
        }
        #expect(Set([from, to]) == [sport.id, food.id])
        #expect(abs(weight - 0.5) < 0.01)
    }

    @Test func theTabALinkCameFromTipsItOneWay() {
        let parent = tab([1, 0, 0])
        let reading = group([parent])
        let other = group([tab([0, 1, 0])])
        let child = tab([0.71, 0.70, 0])
        guard case .between = TabTopics.classify(child, among: [reading, other], background: 0) else {
            Issue.record("expected between without the opener")
            return
        }
        var opened = child
        opened.opener = parent.id
        #expect(TabTopics.classify(opened, among: [reading, other], background: 0) == .group(reading.id))
    }

    @Test func aTabIsNeverItsOwnAnchor() {
        let only = tab([1, 0, 0])
        #expect(TabTopics.score(only, in: group([only])) == nil)
    }

    @Test func threeCloseTabsMakeAGroupAndTwoDoNot() {
        let swift = [tab([1, 0, 0]), tab([0.97, 0.1, 0]), tab([0.95, 0, 0.1])]
        let food = [tab([0, 1, 0]), tab([0.05, 0.98, 0])]
        let stray = tab([0, 0, 1])
        let clusters = TabTopics.clusters(swift + food + [stray])
        #expect(clusters.count == 1)
        #expect(Set(clusters.first ?? []) == Set(swift.map(\.id)))
    }

    @Test func aClusterIsNamedForWhatSetsItApart() {
        let swift = [
            tab([1, 0, 0], title: "Swift Concurrency Tutorial"),
            tab([1, 0, 0], title: "Actors in Swift explained"),
            tab([1, 0, 0], title: "Structured concurrency in Swift | Apple Developer Documentation"),
        ]
        let food = [tab([0, 1, 0], title: "Sourdough bread recipe"), tab([0, 1, 0], title: "Best pasta recipe")]
        #expect(TabTopics.label(for: swift, among: swift + food) == "Swift Concurrency")
    }

    @Test func aClusterWithNothingInCommonButItsSiteIsNamedForTheSite() {
        let tabs = [tab([1], host: "www.youtube.com", title: "Один"), tab([1], host: "www.youtube.com", title: "Два"),
                    tab([1], host: "www.youtube.com", title: "Три")]
        #expect(TabTopics.label(for: tabs, among: tabs) == "youtube.com")
    }

    @Test func theSiteNameComesOffALongTitleOnly() {
        #expect(TabTopics.cleanTitle("How to bake sourdough bread at home - BBC Good Food")
                == "How to bake sourdough bread at home")
        #expect(TabTopics.cleanTitle("Array | Apple Developer Documentation") == "Array | Apple Developer Documentation")
        #expect(TabTopics.cleanTitle("Borscht - Wikipedia", host: "en.wikipedia.org") == "Borscht")
    }
}
