import Foundation
import Testing

@testable import SixCore

/// A row between groups, or next to one: where it stands, its colour, and what a parent's end does to it.
@MainActor
struct TabBlendTests {
    private func layout() -> TilingLayout {
        let layout = TilingLayout()
        layout.updateViewport(CGSize(width: 1600, height: 1000))
        return layout
    }

    private func names(_ layout: TilingLayout) -> [String] {
        layout.workspaces.filter { !$0.isEmpty }.indices.map { layout.title(at: $0) }
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

    private func row(of tab: UUID, in layout: TilingLayout) -> TilingWorkspace? {
        layout.workspaces.first { $0.columns.contains { $0.holds(tab) } }
    }

    @Test func aTabBetweenTwoGroupsStandsBetweenThemAndTheyComeTogether() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, _, food) = groups(layout)
        layout.placeTab(x, in: profile, blend: TilingBlend(from: sport, to: food, weight: 0.4))
        #expect(layout.workspaces.filter { !$0.isEmpty }.map { $0.name.isEmpty ? "·" : $0.name } == ["sport", "·", "food", "code"])
        #expect(names(layout)[1] == "sport · food")
        #expect(row(of: x, in: layout)?.isGroup == true)
        #expect(layout.focusedTabID == x)
    }

    @Test func aSecondTabBetweenTheSameTwoJoinsTheSameRow() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, code, _) = groups(layout)
        let y = UUID()
        layout.insertColumn(tabID: y, in: profile, workspace: 0)
        let first = layout.placeTab(x, in: profile, blend: TilingBlend(from: sport, to: code, weight: 0.5))
        let second = layout.placeTab(y, in: profile, blend: TilingBlend(from: code, to: sport, weight: 0.3))
        #expect(first == second)
    }

    @Test func aTabAlmostInAGroupStandsRightAfterIt() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, _, code, _) = groups(layout)
        layout.placeTab(x, in: profile, blend: TilingBlend(from: code, to: nil, weight: 0.3))
        #expect(names(layout) == ["sport", "code", "≈ code", "food"])
    }

    @Test func aRenamedParentRenamesTheRowAndAClosedOneLeavesItNextToTheOther() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, code, _) = groups(layout)
        let bridge = layout.placeTab(x, in: profile, blend: TilingBlend(from: sport, to: code, weight: 0.25))!
        layout.rename(workspaceAt: layout.workspaces.firstIndex { $0.id == code }!, to: "swift")
        #expect(layout.title(at: layout.workspaces.firstIndex { $0.id == bridge }!) == "sport · swift")

        layout.rename(workspaceAt: layout.workspaces.firstIndex { $0.id == sport }!, to: "")
        #expect(layout.workspaces.first { $0.id == bridge }?.blend == TilingBlend(from: code, to: nil, weight: 0.75))

        layout.rename(workspaceAt: layout.workspaces.firstIndex { $0.id == code }!, to: "")
        #expect(layout.workspaces.first { $0.id == bridge }?.isGroup == false)
    }

    @Test func aNamedRowWhoseParentsAreGoneIsAGroupOfItsOwn() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, _, code, _) = groups(layout)
        let near = layout.placeTab(x, in: profile, blend: TilingBlend(from: code, to: nil, weight: 0.3))!
        layout.rename(workspaceAt: layout.workspaces.firstIndex { $0.id == near }!, to: "kotlin")
        layout.rename(workspaceAt: layout.workspaces.firstIndex { $0.id == code }!, to: "")
        let row = layout.workspaces.first { $0.id == near }
        #expect(row?.blend == nil)
        #expect(row?.isGroup == true)
        #expect(row?.color != nil)
    }

    @Test func groupsTakeThePrimariesFirstAndTheRowBetweenMixesThem() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (x, sport, code, food) = groups(layout)
        #expect([sport, code, food].map { id in layout.workspaces.first { $0.id == id }?.color } == [0, 1, 2])
        layout.placeTab(x, in: profile, blend: TilingBlend(from: code, to: food, weight: 0.5))
        let bridge = row(of: x, in: layout)!
        #expect(bridge.color == nil)
        #expect(layout.groupColor(of: bridge.id) == GroupColor.palette[1].mixed(with: GroupColor.palette[2], by: 0.5))
    }

    /// Sessions saved when the tint was the window's: the row takes it over.
    @Test func aLeanOnAColumnBecomesTheRowsBlend() throws {
        let from = UUID(), to = UUID()
        let data = Data(#"{"tabID":"\#(UUID())","lean":{"from":"\#(from)","to":"\#(to)","weight":0.4}}"#.utf8)
        let column = try JSONDecoder().decode(TilingColumn.self, from: data)
        #expect(column.lean == TilingBlend(from: from, to: to, weight: 0.4))
    }

    @Test func aColumnWithoutALeanStillDecodes() throws {
        let data = Data(#"{"id":"\#(UUID())","tabID":"\#(UUID())"}"#.utf8)
        let column = try JSONDecoder().decode(TilingColumn.self, from: data)
        #expect(column.lean == nil)
    }
}

struct GroupColorTests {
    private func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        guard d > 0 else { return 0 }
        var h: Double
        switch maxC {
        case r: h = (g - b) / d
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    @Test func redAndYellowMakeOrange() {
        let (red, yellow) = (GroupColor.palette[1], GroupColor.palette[2])
        let orange = red.mixed(with: yellow, by: 0.5).srgb
        let h = hue(orange.red, orange.green, orange.blue)
        #expect((20...45).contains(h), "hue \(h)")
        // Not the grey an RGB average goes through: the mix is as saturated as its parents.
        #expect(max(orange.red, orange.green, orange.blue) - min(orange.red, orange.green, orange.blue) > 0.5)
    }

    @Test func blueAndYellowMakeGreen() {
        let green = GroupColor.palette[0].mixed(with: GroupColor.palette[2], by: 0.5).srgb
        #expect((100...200).contains(hue(green.red, green.green, green.blue)))
    }

    @Test func everyColourIsInSRGB() {
        for color in GroupColor.palette {
            let c = color.srgb
            #expect([c.red, c.green, c.blue].allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func aFreeColourIsTheFirstNobodyHas() {
        #expect(GroupColor.free(among: []) == 0)
        #expect(GroupColor.free(among: [0, 2]) == 1)
        #expect(GroupColor.free(among: Array(GroupColor.palette.indices) + [0]) == 1)
    }
}
