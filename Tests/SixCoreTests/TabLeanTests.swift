import Foundation
import Testing

@testable import SixCore

/// A window between two groups: the unnamed row it stands in, and the lean that tints it.
@MainActor
struct TabLeanTests {
    private func layout() -> TilingLayout {
        let layout = TilingLayout()
        layout.updateViewport(CGSize(width: 1600, height: 1000))
        return layout
    }

    private func names(_ layout: TilingLayout) -> [String] {
        layout.workspaces.filter { !$0.isEmpty }.map { $0.name.isEmpty ? "·" : $0.name }
    }

    /// Rows `sport`, `code`, `food`, and `x` alone in the unnamed row at the top.
    private func groups(_ layout: TilingLayout) -> (x: UUID, sport: UUID, code: UUID, food: UUID) {
        let profile = layout.activeProfileID
        let x = UUID()
        layout.insertColumn(tabID: x)
        var ids: [UUID] = []
        for name in ["sport", "code", "food"] {
            let index = layout.workspaceIndex(named: name, in: profile, createIfMissing: true)!
            layout.insertColumn(tabID: UUID(), in: profile, workspace: index)
            ids.append(layout.workspaces[index].id)
        }
        return (x, ids[0], ids[1], ids[2])
    }

    @Test func aTabBetweenTwoGroupsStandsBetweenThemAndTheyComeTogether() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, _, food) = groups(layout)

        let lean = TilingLean(from: sport, to: food, weight: 0.4)
        let bridge = layout.placeTabBetween(x, in: profile, lean: lean)
        #expect(names(layout) == ["sport", "·", "food", "code"])
        let row = layout.workspaces.first { $0.id == bridge }
        #expect(row?.columns.map(\.tabID) == [x])
        #expect(row?.columns.first?.lean == lean)
        #expect(layout.focusedTabID == x)
    }

    @Test func aSecondTabBetweenTheSameTwoJoinsTheSameRow() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, code, _) = groups(layout)
        let y = UUID()
        layout.insertColumn(tabID: y, in: profile, workspace: 0)

        let first = layout.placeTabBetween(x, in: profile, lean: TilingLean(from: sport, to: code, weight: 0.5))
        let second = layout.placeTabBetween(y, in: profile, lean: TilingLean(from: code, to: sport, weight: 0.3))
        #expect(first == second)
        #expect(names(layout) == ["sport", "·", "code", "food"])
    }

    @Test func theLeanGoesWhenTheTabJoinsAGroupOrTheGroupIsUngrouped() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, code, food) = groups(layout)
        layout.placeTabBetween(x, in: profile, lean: TilingLean(from: sport, to: code, weight: 0.5))

        layout.placeTab(x, in: profile, workspace: food, at: 0)
        let inFood = layout.workspaces.first { $0.id == food }?.columns.first { $0.holds(x) }
        #expect(inFood?.lean == nil)

        layout.placeTabBetween(x, in: profile, lean: TilingLean(from: sport, to: code, weight: 0.5))
        let codeIndex = layout.workspaces.firstIndex { $0.id == code }!
        layout.rename(workspaceAt: codeIndex, to: "")
        let column = layout.workspaces.flatMap(\.columns).first { $0.holds(x) }
        #expect(column?.lean == nil)
    }

    /// Strips saved before there was a lean read as having none.
    @Test func aColumnWithoutALeanStillDecodes() throws {
        let data = Data(#"{"id":"\#(UUID())","tabID":"\#(UUID())"}"#.utf8)
        let column = try JSONDecoder().decode(TilingColumn.self, from: data)
        #expect(column.lean == nil)
    }
}
