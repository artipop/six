import Foundation
import Testing

@testable import SixCore

/// Who named a workspace, and what that buys it.
///
/// niri's rule is that a named workspace survives running out of windows, and six kept it — but six
/// has something niri does not: programs that name workspaces. A research run names one after the
/// question it was asked; an agent asks for `workspace: "notes"` and gets one. Those names are
/// labels on a room that already exists, and when they outlived the room the rail filled up with
/// empty rows nobody had named. So the promise is narrower now, and this suite is the promise: a
/// name a person typed holds the row open, a name a program made does not.
///
/// A second front end draws from the same rule (Android has the model ported line for line), which
/// is why these are here and not in the app's tests.
@MainActor
struct NiriLayoutWorkspaceNameTests {

    private func layout(viewport: CGSize = CGSize(width: 1600, height: 1000)) -> NiriLayout {
        let layout = NiriLayout()
        layout.updateViewport(viewport)
        return layout
    }

    private func names(_ layout: NiriLayout) -> [String] {
        layout.workspaces.map(\.name)
    }

    /// The sequence every `workspaceIndex(named:createIfMissing:)` caller performs: name a row, then
    /// put a window in it. The row must still be there on the next line — this is the case that
    /// makes the rule a transition rather than an invariant.
    @Test func aRowIsNotPrunedBetweenBeingNamedAndBeingFilled() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID())

        guard let index = layout.workspaceIndex(named: "tickets to KZ", in: profile, createIfMissing: true) else {
            Issue.record("no workspace was created")
            return
        }
        #expect(layout.workspaces[index].name == "tickets to KZ")

        let document = UUID()
        layout.insertColumn(tabID: document, in: profile, workspace: index)
        #expect(layout.location(ofTabID: document, in: profile)?.workspace == index)
    }

    /// The pile this was written for: the run ends, its windows are closed, and the row goes with
    /// them instead of standing there with a question on it forever.
    @Test func aRowAProgramNamedGivesTheNameBackWhenItEmpties() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID()) // a workspace that stays, so the named one is not the only row

        let index = layout.workspaceIndex(named: "research", in: profile, createIfMissing: true)!
        let document = UUID()
        layout.insertColumn(tabID: document, in: profile, workspace: index)
        #expect(names(layout).contains("research"))

        layout.removeColumn(tabID: document)
        #expect(!names(layout).contains("research"))
        // And niri's dynamic workspaces still hold: what is left is the row with a window in it and
        // exactly one empty one at the end.
        #expect(layout.workspaces.count == 2)
        #expect(layout.workspaces.last?.isEmpty == true)
    }

    /// The reservation, which is what naming a workspace is for: it holds the row open with nothing
    /// in it, before and after.
    @Test func aRowAPersonNamedStaysWhenItEmpties() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID())
        let index = layout.workspaceIndex(named: "reading", in: profile, createIfMissing: true)!
        let window = UUID()
        layout.insertColumn(tabID: window, in: profile, workspace: index)

        layout.focusWorkspace(at: index)
        layout.rename(workspaceAt: index, to: "Reading") // typed into the plate: now it is a promise

        layout.removeColumn(tabID: window)
        #expect(names(layout).contains("Reading"))
        #expect(layout.workspaces.first { $0.name == "Reading" }?.isEmpty == true)
    }

    /// Clearing the name hands the row back to the dynamic-workspace rule, the way the plate's
    /// **Clear Name** says it does.
    @Test func clearingTheNameGivesTheRowBack() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID())
        let index = layout.workspaceIndex(named: "reading", in: profile, createIfMissing: true)!
        layout.focusWorkspace(at: index)
        layout.rename(workspaceAt: index, to: "Reading")
        layout.rename(workspaceAt: index, to: "")

        #expect(layout.workspaces.count == 2) // the row with a window, and one empty one at the end
    }

    /// A window carried out of the last row of a workspace empties it just as closing one does, so
    /// the name goes the same way.
    @Test func carryingTheLastWindowOutEmptiesTheRowToo() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID())
        let index = layout.workspaceIndex(named: "research", in: profile, createIfMissing: true)!
        let window = UUID()
        layout.insertColumn(tabID: window, in: profile, workspace: index)

        layout.moveColumn(tabID: window, in: profile, toWorkspace: 0)
        #expect(!names(layout).contains("research"))
    }

    /// What a snapshot written before the distinction comes back as. The rows in it look identical —
    /// a name and no windows — so the one thing that can be said about them honestly is that nobody
    /// can now say who named them, and the rail is better off without them.
    @Test func restoreDropsTheNamedRowsNobodyIsBehind() {
        let layout = layout()
        let profile = layout.activeProfileID
        let strip = NiriStrip(
            workspaces: [
                NiriWorkspace(name: "research", columns: []),                        // an old, unattributed name
                NiriWorkspace(name: "kept", namedByHand: true, columns: []),          // a reservation
                NiriWorkspace(name: "working", columns: [NiriColumn(tabID: UUID())]), // has a window, so it stays
                NiriWorkspace()
            ],
            focus: 2
        )
        layout.restore(strips: [profile: strip])

        #expect(names(layout) == ["kept", "working", ""])
        // The focus followed the row it was on rather than the index it was at.
        #expect(layout.focusedWorkspaceIndex == 1)
    }
}
