import SwiftUI

/// "Delete the workspace «Tickets»?" — asked when a named workspace loses its last window.
///
/// An unnamed row disappears the moment it empties and always has: there is nothing to ask about, it
/// happens a dozen times a day, and a question every time would be a browser asking permission to
/// tidy up after itself. A name is the exception, and not because of who typed it — a research run
/// names a workspace after its question, an agent asks for `workspace: "notes"` — but because a name
/// is the one thing on a rail that was put there in words, and taking it away without saying so is
/// taking away work.
///
/// So the rule underneath is the same everywhere (`NiriLayout.askBeforeRemoving`) and this is the
/// whole of the difference: yes and the row goes, no and it stands.
///
/// A dialog rather than an undo, because there is nothing to look at afterwards: the row it is about
/// is empty, off the screen more often than not, and a banner offering to bring back something that
/// was never visible is a banner nobody reads in time.
struct WorkspaceRemovalDialog: ViewModifier {
    @Environment(BrowserState.self) private var browser

    func body(content: Content) -> some View {
        let pending = browser.layout.workspaceToRemove
        content.confirmationDialog(
            Text("Delete the workspace “\(pending?.name ?? "")”?"),
            isPresented: Binding(get: { pending != nil }, set: { shown in
                // Dismissed by the escape hatch every dialog has — clicking away, ⎋ — which is not an
                // answer and must not be read as one. Keeping the row is what "no answer" means.
                guard !shown, let pending else { return }
                browser.layout.keepWorkspace(pending.id)
            }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            Button("Delete Workspace", role: .destructive) { browser.layout.removeWorkspace(pending.id) }
            Button("Keep It", role: .cancel) { browser.layout.keepWorkspace(pending.id) }
        } message: { _ in
            Text("Its last window has been closed. Kept, it stays on the rail with its name and nothing in it.")
        }
    }
}

extension View {
    func workspaceRemovalDialog() -> some View {
        modifier(WorkspaceRemovalDialog())
    }
}
