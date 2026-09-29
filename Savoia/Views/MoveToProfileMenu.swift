import SwiftUI

/// The profiles this tab could go to — the items behind "Move to Profile" in the tab's menu and the
/// page's right-click. Its own is not among them, and the menu is left out when there is only one.
///
/// Names and nothing else, deliberately. A profile is a colour everywhere else in Savoia, but a menu on
/// the Mac is an `NSMenu` underneath and the only picture it reliably draws is a symbol; a coloured
/// dot that renders as a black circle in half the menus it appears in is worse than the name alone.
///
/// A destination that would refuse the window (`BrowserState.canMove`) is disabled rather than
/// dropped: a document cannot enter a private profile, and a list that quietly left one out would
/// read as the browser having forgotten it.
struct MoveToProfileItems: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser

    var body: some View {
        ForEach(browser.profiles.filter { $0.id != tab.profileID }) { profile in
            Button(profile.name) { browser.moveTab(tab.id, toProfile: profile.id) }
                .disabled(!browser.canMove(tab, to: profile))
        }
    }
}
