import SwiftUI

// Every sheet in six is opened from a menu item that is a scene away from the view holding the
// state; a focused value carries the one closure across. The phone has no menu bar, but the
// sheets are the same views, so the plumbing is shared.

// MARK: - Focus plumbing for ⌘L

struct FocusAddressBarAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var focusAddressBar: FocusAddressBarAction?
    /// Translate the focused page, or put it back — one item, because the menu says which it is.
    @Entry var translatePage: FocusAddressBarAction?
}
