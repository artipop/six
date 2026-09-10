import Foundation
import Testing

@testable import SixCore

/// The ⌃Tab ring, which is two orders over a list of ids and nothing else.
///
/// Both of them got out wrong by eye — first the halves of a split appearing twice as the same
/// picture, then a pair drawn in the right order but with another window standing between its two
/// halves, which on the rail cannot happen. Neither is visible in a count and both are arithmetic,
/// so they are asked about here instead of being looked at.
@MainActor
struct WindowSwitcherTests {

    /// A rail of plain windows, one per column.
    private func windows(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    /// The ring as a switcher with no memory would open it: every window its own column.
    private func opened(_ switcher: WindowSwitcher, _ ids: [UUID], current: UUID?,
                        sharing pair: [UUID] = []) {
        // Two ids named as `sharing` stand in one column, the way a split does: they are one place
        // on the rail, and each is its own stop only because the focus is in that column.
        let column = UUID()
        switcher.open(ids, current: current, stop: { $0 }, group: { pair.contains($0) ? column : $0 })
    }

    // MARK: Memory

    /// The window being read is first, so the first press lands on the one before it.
    @Test func theRingOpensOnTheWindowYouAreIn() {
        let switcher = WindowSwitcher()
        let ids = windows(3)
        opened(switcher, ids, current: ids[2])

        #expect(switcher.selection == ids[2])
        switcher.step(1)
        #expect(switcher.selection != ids[2]) // somewhere else, and the ring is not stuck
    }

    /// One press is a toggle between the last two, which is the whole of what ⌃Tab is for.
    @Test func aLonePressIsAToggle() {
        let switcher = WindowSwitcher()
        let ids = windows(4)
        for id in [ids[3], ids[1], ids[0]] { switcher.note(id) } // 0 last, 1 before it
        opened(switcher, ids, current: ids[0])

        switcher.step(1)
        #expect(switcher.selection == ids[1])
    }

    // MARK: The two halves of a column

    /// They are drawn **next to each other**, whatever order they were used in: on the rail those
    /// two are side by side, and a window standing between them is a thing the rail cannot do.
    @Test func theHalvesOfAColumnAreDrawnTogether() {
        let switcher = WindowSwitcher()
        let ids = windows(4)
        let (left, right) = (ids[0], ids[1]) // one column, left then right along the rail
        // Used at different times, with two other windows in between: the case that put a stranger
        // between the halves.
        for id in [right, ids[2], ids[3], left] { switcher.note(id) }
        opened(switcher, ids, current: left, sharing: [left, right])

        let places = [switcher.ring.firstIndex(of: left), switcher.ring.firstIndex(of: right)]
        #expect(places.allSatisfy { $0 != nil })
        #expect(abs((places[0] ?? 0) - (places[1] ?? 0)) == 1)
        // And in the order they stand on the rail, from whichever of them you came.
        #expect((places[0] ?? 0) < (places[1] ?? 0))
    }

    /// The same ring from the other half: the pair does not turn over, only the highlight moves.
    @Test func theHalvesDoNotSwapWhenTheFocusMoves() {
        let switcher = WindowSwitcher()
        let ids = windows(3)
        let (left, right) = (ids[0], ids[1])

        opened(switcher, ids, current: left, sharing: [left, right])
        let fromTheLeft = switcher.ring
        #expect(switcher.selection == left)

        let other = WindowSwitcher()
        for id in [left, right] { other.note(id) }
        opened(other, ids, current: right, sharing: [left, right])
        #expect(other.ring == fromTheLeft)
        #expect(other.selection == right)
    }

    /// Everything else keeps its place in memory: only the pair moves, and only to arrive together.
    @Test func thePairMovesAsOneAndNothingElseMoves() {
        let switcher = WindowSwitcher()
        let ids = windows(4)
        let (left, right) = (ids[2], ids[3])
        for id in [right, ids[0], ids[1], left] { switcher.note(id) }
        opened(switcher, ids, current: left, sharing: [left, right])

        // Memory, most recent first: the half being read, then the two windows used before it, and
        // the other half last of all — it was used first and is four presses away.
        #expect(switcher.walk == [left, ids[1], ids[0], right])
        // Drawn: the pair arrives together where the nearer of the two falls, and the rest keep the
        // places memory gave them. Nothing stands between the halves.
        #expect(switcher.ring == [left, right, ids[1], ids[0]])
    }

    /// Stepping follows memory and the highlight goes to wherever that stop is drawn — which for a
    /// pair can be the card on the left. The key names a window; the card for it is where the window
    /// is.
    @Test func steppingFollowsMemoryAndTheHighlightFollowsTheRail() {
        let switcher = WindowSwitcher()
        let ids = windows(3)
        let (left, right) = (ids[0], ids[1])
        for id in [left, right] { switcher.note(id) } // right last, left before it
        opened(switcher, ids, current: right, sharing: [left, right])

        #expect(switcher.ring == [left, right, ids[2]])
        #expect(switcher.selection == right)
        switcher.step(1) // memory says the left half is next
        #expect(switcher.selection == left)
        #expect(switcher.index == 0) // and it is the card on the left
    }

    // MARK: Closing under an open ring

    @Test func aWindowClosingLeavesTheRingStanding() {
        let switcher = WindowSwitcher()
        let ids = windows(3)
        opened(switcher, ids, current: ids[0])
        switcher.step(1)
        let gone = switcher.selection

        switcher.forget(gone ?? ids[1])
        #expect(switcher.ring.count == 2)
        #expect(!switcher.walk.contains(gone ?? ids[1]))
        #expect(switcher.isOpen)
        #expect(switcher.selection != nil)
    }
}
