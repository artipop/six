import SwiftUI

/// Walking a list of rows from the search field above it.
///
/// Every searchable panel in six has the same shape — a field at the top, a `List(selection:)`
/// under it — and the same hole: a `List` answers `↑` and `↓` only while it holds the focus, and the
/// focus is in the field, which is where a person typing a query wants it and where the panel puts
/// it on open. So `⌘Y` and `⌘⌥B` documented arrow keys that only worked if you first clicked the
/// list, which is the click the keyboard was there to avoid. The field walks the rows on the list's
/// behalf instead — the start page has always done this for its own completions, and this is that,
/// factored out.
///
/// `⌫` stays the list's, because in a field it is a character being deleted and nothing else; the
/// row is removed with `⌘⌫`, which is what a mail app means by it.
extension View {
    func walksRows<ID: Hashable>(_ ids: [ID], selection: Binding<ID?>, remove: @escaping (ID) -> Void) -> some View {
        modifier(RowWalking(ids: ids, selection: selection, remove: remove))
    }
}

private struct RowWalking<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var selection: ID?
    let remove: (ID) -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(keys: [.delete], phases: .down) { press in
                guard press.modifiers.contains(.command), let selection else { return .ignored }
                let next = ids.firstIndex(of: selection).map { min($0, ids.count - 2) }
                remove(selection)
                // Land on the row that takes its place, so a run of ⌘⌫ clears a stretch of the list
                // without going back to the pointer between each one.
                self.selection = next.flatMap { ids.indices.contains($0 + 1) ? ids[$0 + 1] : nil }
                return .handled
            }
    }

    /// One row on, from wherever the selection is — or onto the first row, which is what `↓` on an
    /// untouched list means everywhere else.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = delta > 0 ? ids[0] : ids[ids.count - 1]
            return .handled
        }
        let next = current + delta
        guard ids.indices.contains(next) else { return .handled }
        selection = ids[next]
        return .handled
    }
}
