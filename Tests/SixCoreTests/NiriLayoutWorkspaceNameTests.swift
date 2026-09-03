import Foundation
import Testing

@testable import SixCore

/// What happens to a workspace when its last window goes, and to the name on it.
///
/// niri's rule is that a named workspace survives running out of windows, and six kept it for as
/// long as naming one was something only a person did. It isn't: a research run names a workspace
/// after the question it was asked, an agent asks for `workspace: "notes"` and gets one, and every
/// one of those names made a row immortal — a browser that answers questions for a living silting
/// up with empty rows carrying last week's questions.
///
/// Six could have guessed which names were reservations. It asks instead: the rule is the same for
/// every named row, and the person who is there answers it. This suite is that rule — that the
/// question is raised for a row that *became* empty and never for one that was made a moment ago,
/// that yes removes it and no leaves it standing, and that a question stops being asked when it
/// stops being true.
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

    /// A named workspace with a window in it, and the window's id.
    private func named(_ layout: NiriLayout, _ name: String) -> (index: Int, window: UUID) {
        let profile = layout.activeProfileID
        let index = layout.workspaceIndex(named: name, in: profile, createIfMissing: true)!
        let window = UUID()
        layout.insertColumn(tabID: window, in: profile, workspace: index)
        return (index, window)
    }

    /// The sequence every `workspaceIndex(named:createIfMissing:)` caller performs: name a row, then
    /// put a window in it. Nothing is asked about it — it has not lost anything — and the row must
    /// still be there on the next line.
    @Test func aRowMadeByNameIsNotAskedAbout() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let profile = layout.activeProfileID

        let index = layout.workspaceIndex(named: "tickets to KZ", in: profile, createIfMissing: true)!
        #expect(layout.workspaces[index].name == "tickets to KZ")
        #expect(layout.workspaceToRemove == nil)

        let document = UUID()
        layout.insertColumn(tabID: document, in: profile, workspace: index)
        #expect(layout.location(ofTabID: document, in: profile)?.workspace == index)
        #expect(layout.workspaceToRemove == nil)
    }

    /// The last window closes: the row is still there, and so is the question about it. Nothing is
    /// removed until it is answered — that is the whole point of asking.
    @Test func theLastWindowLeavingRaisesTheQuestionAndNothingElse() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let (_, window) = named(layout, "research")

        layout.removeColumn(tabID: window)
        #expect(layout.workspaceToRemove?.name == "research")
        #expect(names(layout).contains("research"))
    }

    /// Yes.
    @Test func answeringYesTakesTheRow() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let (_, window) = named(layout, "research")
        layout.removeColumn(tabID: window)

        layout.removeWorkspace(layout.workspaceToRemove!.id)
        #expect(!names(layout).contains("research"))
        #expect(layout.workspaceToRemove == nil)
        // And niri's dynamic workspaces still hold: the row with a window, and one empty one at the end.
        #expect(layout.workspaces.count == 2)
        #expect(layout.workspaces.last?.isEmpty == true)
    }

    /// No. The row stands with its name and nothing in it, the way a named row always has — and it
    /// is not asked about again until it is filled and emptied again.
    @Test func answeringNoLeavesTheRowStanding() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let (index, window) = named(layout, "reading")
        layout.removeColumn(tabID: window)

        layout.keepWorkspace(layout.workspaceToRemove!.id)
        #expect(names(layout).contains("reading"))
        #expect(layout.workspaceToRemove == nil)

        let again = UUID()
        layout.insertColumn(tabID: again, in: layout.activeProfileID, workspace: index)
        layout.removeColumn(tabID: again)
        #expect(layout.workspaceToRemove?.name == "reading") // filled and emptied again: asked again
    }

    /// An unnamed row is not asked about, ever. It is what closing the last window on a rail does a
    /// dozen times a day, and there is nothing to lose by it.
    @Test func anUnnamedRowGoesWithoutAQuestion() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let window = UUID()
        layout.moveColumnToWorkspace(1) // a second row, unnamed
        layout.insertColumn(tabID: window)

        layout.removeColumn(tabID: window)
        #expect(layout.workspaceToRemove == nil)
    }

    /// A question outlives the moment it was asked in: the row can be filled again while it is up.
    /// Then there is nothing to remove, and the question goes rather than the workspace.
    @Test func aRowThatFillsAgainTakesItsQuestionWithIt() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let (index, window) = named(layout, "research")
        layout.removeColumn(tabID: window)
        #expect(layout.workspaceToRemove != nil)

        layout.insertColumn(tabID: UUID(), in: layout.activeProfileID, workspace: index)
        #expect(layout.workspaceToRemove == nil)
        #expect(names(layout).contains("research"))
    }

    /// Carrying the last window out of a row empties it exactly as closing one does, so it asks the
    /// same question — the rule is about the row, not about which gesture emptied it.
    @Test func everyWayOfEmptyingARowAsksTheSameQuestion() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let profile = layout.activeProfileID
        let (_, window) = named(layout, "research")

        layout.moveColumn(tabID: window, in: profile, toWorkspace: 0)
        #expect(layout.workspaceToRemove?.name == "research")
    }

    /// Several rows can empty at once — a profile being cleared, a rail being taken apart — and each
    /// gets its own question, in the order they emptied. A question that overwrote another would
    /// delete a workspace nobody was asked about.
    @Test func questionsQueueRatherThanOverwriteEachOther() {
        let layout = layout()
        layout.insertColumn(tabID: UUID())
        let first = named(layout, "first")
        let second = named(layout, "second")

        layout.removeColumn(tabID: first.window)
        layout.removeColumn(tabID: second.window)
        #expect(layout.pendingRemovals.map(\.name) == ["first", "second"])

        layout.removeWorkspace(layout.workspaceToRemove!.id)
        #expect(layout.workspaceToRemove?.name == "second")
    }

    /// The profile is being deleted whole, and its windows are closed one by one on the way out.
    /// Being asked eight times whether to keep a workspace inside something you have just thrown
    /// away is not a question.
    @Test func aProfileGoingAwayTakesItsQuestionsWithIt() {
        let layout = layout()
        let profile = layout.activeProfileID
        layout.insertColumn(tabID: UUID())
        let (_, window) = named(layout, "research")
        layout.removeColumn(tabID: window)
        #expect(layout.workspaceToRemove != nil)

        layout.removeProfile(profile)
        #expect(layout.pendingRemovals.isEmpty)
    }
}
