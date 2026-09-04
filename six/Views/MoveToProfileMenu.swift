import SwiftUI

/// The profiles this window could go to — the items behind "Move to Profile", wherever that menu is
/// opened from.
///
/// A file of its own because both fronts carry it and neither owns it: the Mac's is in the window's
/// menu (`ColumnMenu`, and so the page's right-click), the phone's is in the ⋯ menu, and
/// `NiriStripView` — where the first one lives — is the Mac's alone.
///
/// The profiles this window could go to. Its own is not among them — a move to where it already is
/// has nothing to do — and the whole menu is left out when there is only one profile, rather than
/// shown empty.
///
/// Names and nothing else, deliberately. A profile is a colour everywhere else in six, but a menu on
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
