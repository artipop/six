import Foundation
import Testing

@testable import SavoiaCore

/// Two tabs shown side by side in one column, and every way in and out of that. The halves stay
/// tabs in their own right: each is closed on its own, and taking the pair apart closes nothing.
@MainActor
struct TilingLayoutSplitTests {

    /// A group of `count` tabs, left to right, with the last one focused.
    @discardableResult
    private func fill(_ layout: TilingLayout, _ count: Int) -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        for id in ids { layout.insertColumn(tabID: id) }
        return ids
    }

    /// The tabs of a workspace, column by column — a pair is one entry with two tabs in it.
    private func row(_ layout: TilingLayout, workspace: Int = 0) -> [[UUID]] {
        layout.workspaces[workspace].columns.map(\.tabIDs)
    }

    // MARK: Making one

    /// The first tab keeps its place and the second arrives on its right, wherever it stood.
    @Test func theSecondTabComesInBesideTheFirst() {
        let layout = TilingLayout()
        let ids = fill(layout, 3)

        #expect(layout.split(tabID: ids[0], with: ids[2], in: layout.activeProfileID))
        #expect(row(layout) == [[ids[0], ids[2]], [ids[1]]])
        #expect(layout.columnMates(of: ids[2]) == [ids[0], ids[2]])
    }

    /// Two is the ceiling: a pair takes no third.
    @Test func aColumnNeverHoldsMoreThanTwo() {
        let layout = TilingLayout()
        let ids = fill(layout, 3)
        let profile = layout.activeProfileID
        layout.split(tabID: ids[0], with: ids[1], in: profile)

        #expect(!layout.split(tabID: ids[0], with: ids[2], in: profile))
        #expect(row(layout).allSatisfy { $0.count <= 2 })
        #expect(row(layout).flatMap { $0 }.count == ids.count)
    }

    /// A tab is not split with itself, and a tab of another profile is not found.
    @Test func aTabIsNotSplitWithItselfOrAStranger() {
        let layout = TilingLayout()
        let ids = fill(layout, 2)
        let profile = layout.activeProfileID

        #expect(!layout.split(tabID: ids[0], with: ids[0], in: profile))
        #expect(!layout.split(tabID: ids[0], with: UUID(), in: profile))
        #expect(row(layout) == [[ids[0]], [ids[1]]])
    }

    // MARK: Taking one apart

    /// The right half becomes a column of its own just after the pair, and the focus stays on the
    /// tab that was named.
    @Test func separatingPutsTheRightHalfBesideIt() {
        let layout = TilingLayout()
        let ids = fill(layout, 2)
        layout.split(tabID: ids[0], with: ids[1], in: layout.activeProfileID)

        layout.separate(tabID: ids[1])
        #expect(row(layout) == [[ids[0]], [ids[1]]])
        #expect(layout.focusedTabID == ids[1])
    }

    /// Closing half of a pair is closing one tab: the other keeps the column.
    @Test func closingOneHalfLeavesTheOtherWhereItStood() {
        let layout = TilingLayout()
        let ids = fill(layout, 3)
        layout.split(tabID: ids[1], with: ids[2], in: layout.activeProfileID)

        layout.removeColumn(tabID: ids[2])
        #expect(row(layout) == [[ids[0]], [ids[1]]])
        #expect(layout.focusedTabID == ids[1])
    }

    /// Both halves are on screen, so both are live.
    @Test func bothHalvesAreVisible() {
        let layout = TilingLayout()
        let ids = fill(layout, 2)
        layout.split(tabID: ids[0], with: ids[1], in: layout.activeProfileID)
        layout.focus(tabID: ids[0])

        #expect(layout.visibleTabIDs == Set(ids))
    }
}
