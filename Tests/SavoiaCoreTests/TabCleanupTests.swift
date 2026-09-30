import Foundation
import Testing

@testable import SavoiaCore

/// Which tabs `TabCleaner` offers to close, with vectors laid along axes so a cosine is known by eye.
struct TabCleanupTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var since: Date { now.addingTimeInterval(-7 * 86_400) }

    private func tab(_ vector: [Float], daysAgo: Double, host: String = "", group: UUID? = nil) -> TabCleanup.Tab {
        TabCleanup.Tab(id: UUID(), vector: vector, host: host, seenAt: now.addingTimeInterval(-daysAgo * 86_400), group: group)
    }

    private func visits(_ vector: [Float], _ count: Int, host: String = "") -> [TabCleanup.Interest] {
        Array(repeating: TabCleanup.Interest(vector: vector, host: host), count: count)
    }

    @Test func anOldTabAboutWhatIsNoLongerReadIsOffered() {
        let food = tab([0, 1, 0], daysAgo: 10)
        let swift = tab([0.95, 0.05, 0], daysAgo: 10)
        let offered = TabCleanup.abandoned([food, swift], history: visits([1, 0, 0], 5), since: since)
        #expect(offered == [food.id])
    }

    @Test func aTabLookedAtWithinThePeriodStays() {
        let food = tab([0, 1, 0], daysAgo: 2)
        #expect(TabCleanup.abandoned([food], history: visits([1, 0, 0], 5), since: since).isEmpty)
    }

    @Test func aGroupWithOneTabStillReadKeepsTheRest() {
        let group = UUID()
        let old = tab([0, 1, 0], daysAgo: 20, group: group)
        let read = tab([0, 0, 1], daysAgo: 1, group: group)
        #expect(TabCleanup.abandoned([old, read], history: visits([1, 0, 0], 5), since: since).isEmpty)
    }

    @Test func aRecentTabOnTheSameTopicKeepsAnOldOne() {
        let old = tab([0, 1, 0, 0], daysAgo: 20)
        let recent = tab([0.05, 0.99, 0, 0], daysAgo: 1)
        let others = [tab([0, 0, 1, 0], daysAgo: 20), tab([0, 0, 0.9, 0.44], daysAgo: 20)]
        let offered = TabCleanup.abandoned([old, recent] + others, history: visits([1, 0, 0, 0], 5), since: since)
        #expect(!offered.contains(old.id))
        #expect(offered.count == 2)
    }

    @Test func nothingIsOfferedAfterAPeriodAway() {
        let food = tab([0, 1, 0], daysAgo: 30)
        #expect(TabCleanup.abandoned([food], history: visits([1, 0, 0], 2), since: since).isEmpty)
    }

    @Test func theLongestUnseenComeFirst() {
        let week = tab([0, 1, 0], daysAgo: 8)
        let month = tab([0, 0.9, 0.44], daysAgo: 30)
        let offered = TabCleanup.abandoned([week, month], history: visits([1, 0, 0], 5), since: since)
        #expect(offered == [month.id, week.id])
    }
}

extension TabCleanupTests {
    /// A period spent on one topic does not make that topic's own old tabs look ordinary.
    @Test func aTopicReadAllPeriodKeepsItsOldTabs() {
        let swift = [tab([0.95, 0.05, 0], daysAgo: 10), tab([0.9, 0.1, 0], daysAgo: 10)]
        let other = [tab([0, 0, 1], daysAgo: 10), tab([0, 0.44, 0.9], daysAgo: 10)]
        let offered = TabCleanup.abandoned(swift + other, history: visits([1, 0, 0], 50), since: since)
        #expect(Set(offered) == Set(other.map(\.id)))
    }

    /// A tab with no tab near it has nothing to be measured against, and stays.
    @Test func aTabAloneOnItsTopicStays() {
        let lone = tab([0, 0, 1], daysAgo: 10)
        let swift = tab([0.95, 0.05, 0], daysAgo: 10)
        #expect(TabCleanup.abandoned([lone, swift], history: visits([1, 0, 0], 5), since: since).isEmpty)
    }
}
