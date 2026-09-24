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
    /// Translate whatever is selected, in the system's own popover.
    @Entry var translateSelection: FocusAddressBarAction?
    /// ⌘F: bring up the focused window's find bar, or give it the keyboard if it is already up.
    @Entry var showFindBar: FocusAddressBarAction?
    /// Present only while the window is a tab bar, so the menu bar can carry the keys a row of
    /// tabs has (⌘1…⌘9, ⌘⇧[ ⌘⇧]) and drop the row's.
    @Entry var tabBar: TabBarActions?
}

/// What the menu bar can do to the tab bar.
struct TabBarActions {
    let select: (Int) -> Void
    let step: (Int) -> Void
}
