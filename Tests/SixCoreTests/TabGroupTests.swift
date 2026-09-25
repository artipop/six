import Foundation
import Testing

@testable import SixCore

/// The tab bar is the strip seen another way (`InterfaceStyle.tabs`), and these are the few
/// things it asks of the strip that the row never did: a window dropped at a place in a row, a
/// window given a row of its own, a row folded to its name — and a key table that goes quiet where
/// there is no row to walk.
@MainActor
struct TabGroupTests {

    private func layout() -> TilingLayout {
        let layout = TilingLayout()
        layout.updateViewport(CGSize(width: 1600, height: 1000))
        return layout
    }

    private func row(_ layout: TilingLayout, _ index: Int) -> [UUID] {
        layout.workspaces[index].columns.flatMap(\.tabIDs)
    }

    @Test func aTabDraggedAlongItsRowLandsWhereItWasDropped() {
        let layout = layout()
        let (a, b, c) = (UUID(), UUID(), UUID())
        for id in [a, b, c] { layout.insertColumn(tabID: id) }
        let group = layout.workspaces[0].id
        #expect(row(layout, 0) == [a, b, c])

        // Dropped on the right half of `c`: after it, at the position the row showed before `a` left.
        layout.placeTab(a, in: layout.activeProfileID, workspace: group, at: 3)
        #expect(row(layout, 0) == [b, c, a])
        #expect(layout.focusedTabID == a)

        layout.placeTab(a, in: layout.activeProfileID, workspace: group, at: 0)
        #expect(row(layout, 0) == [a, b, c])
    }

    @Test func aTabDroppedOnAnotherGroupJoinsItAndOpensIt() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (a, b) = (UUID(), UUID())
        layout.insertColumn(tabID: a)
        let work = layout.workspaceIndex(named: "work", in: profile, createIfMissing: true)!
        layout.insertColumn(tabID: b, in: profile, workspace: work)
        let workID = layout.workspaces[work].id
        layout.setCollapsed(true, workspace: workID)

        layout.placeTab(a, in: profile, workspace: workID, at: 0)
        let landed = layout.workspaces.firstIndex { $0.id == workID }!
        #expect(row(layout, landed) == [a, b])
        #expect(layout.workspaces[landed].isCollapsed == false)
        #expect(layout.focusedTabID == a)
    }

    /// A tab is one page: half a split dragged away leaves the other half standing in its column.
    @Test func halfASplitDraggedAwayLeavesTheOtherHalf() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (a, b, c) = (UUID(), UUID(), UUID())
        layout.insertColumn(tabID: a)
        layout.insertColumn(tabID: b)
        layout.insertColumn(tabID: c)
        #expect(layout.split(tabID: a, with: b, in: profile))
        #expect(layout.workspaces[0].columns.count == 2)

        layout.placeTab(b, in: profile, workspace: layout.workspaces[0].id, at: 2)
        let columns: [[UUID]] = layout.workspaces[0].columns.map(\.tabIDs)
        #expect(columns == [[a], [c], [b]])
    }

    @Test func aNewGroupStandsRightAfterTheOneTheTabLeft() {
        let layout = layout()
        let profile = layout.activeProfileID
        let (a, b, c) = (UUID(), UUID(), UUID())
        layout.insertColumn(tabID: a)
        layout.insertColumn(tabID: b)
        let later = layout.workspaceIndex(named: "later", in: profile, createIfMissing: true)!
        layout.insertColumn(tabID: c, in: profile, workspace: later)

        let created = layout.placeTabInNewWorkspace(a, in: profile)
        #expect(created != nil)
        let rows: [[UUID]] = (0..<3).map { row(layout, $0) }
        #expect(rows == [[b], [a], [c]])
        #expect(layout.workspaces[1].id == created)
        #expect(layout.focusedTabID == a)
    }

    /// Folded is kept with the strip, and a strip written before there was such a thing reads as
    /// every group open.
    @Test func foldedSurvivesTheSessionFileAndItsAbsenceMeansOpen() throws {
        var strip = TilingStrip()
        strip.workspaces[0].columns = [TilingColumn(tabID: UUID())]
        strip.workspaces[0].collapsed = true
        let data = try JSONEncoder().encode(strip)
        let decoded = try JSONDecoder().decode(TilingStrip.self, from: data)
        #expect(decoded.workspaces[0].isCollapsed)

        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var saved = try #require(old["workspaces"] as? [[String: Any]])
        saved[0].removeValue(forKey: "collapsed")
        old["workspaces"] = saved
        let legacy = try JSONSerialization.data(withJSONObject: old)
        let read = try JSONDecoder().decode(TilingStrip.self, from: legacy)
        #expect(read.workspaces[0].isCollapsed == false)
    }

    // MARK: Keys

    private func action(_ chord: KeyChord, in context: KeyContext) -> KeyAction? {
        let row: KeyBinding? = KeyBindings.all.first(where: { (binding: KeyBinding) -> Bool in
            binding.matches(code: chord.key.rawValue, character: nil, held: chord.modifiers, in: context)
        })
        return row?.action
    }

    @Test func theRowsKeysAreOffWithTheTabsUp() {
        let tabs = KeyContext(window: .main, showsTabs: true)
        #expect(action(KeyChord(.option, .rightArrow), in: tabs) == nil)
        #expect(action(KeyChord(.option, .upArrow), in: tabs) == nil)
        #expect(action(KeyChord(.option, .w), in: tabs) == nil)
        #expect(action(KeyChord(.option, .o), in: tabs) == nil)
        #expect(action(KeyChord([.control, .option], .leftArrow), in: tabs) == nil)
        #expect(action(KeyChord([], .escape), in: tabs) == nil)
        // …and in the row they are exactly where they were.
        #expect(action(KeyChord(.option, .rightArrow), in: KeyContext(window: .main)) == .focusColumn(1))
    }

    @Test func thePagesVerbsAndControlTabStayWithTheTabsUp() {
        let tabs = KeyContext(window: .main, showsTabs: true)
        #expect(action(KeyChord(.control, .tab), in: tabs) == .stepSwitcher(1))
        #expect(action(KeyChord([.control, .shift], .tab), in: tabs) == .stepSwitcher(-1))
        #expect(action(KeyChord([.option, .shift], .t), in: tabs) == .translateSelection)
        #expect(action(KeyChord([.option, .shift], .p), in: tabs) == .pictureInPicture)
        #expect(action(KeyChord(KeyBindings.copyAddressChord, .c), in: tabs) == .copyAddress)
    }

    /// The ring works over the tab bar as it does over the row: once it is open its own keys answer.
    @Test func theRingKeepsItsKeysWithTheTabsUp() {
        let ring = KeyContext(window: .main, isSwitching: true, showsTabs: true)
        #expect(action(KeyChord(.control, .tab), in: ring) == .stepSwitcher(1))
        #expect(action(KeyChord(.control, .rightArrow), in: ring) == .walkSwitcher(1))
        #expect(action(KeyChord(.control, .returnKey), in: ring) == .landSwitcher)
        #expect(action(KeyChord(.control, .escape), in: ring) == .cancelSwitcher)
    }
}
