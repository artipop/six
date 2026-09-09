import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// The profile switcher behind the chip in the top bar: a dropdown, the shape `ProfileMenu.swift`
/// argues for on the Mac — "a row of coloured circles is fine for two profiles and unreadable for
/// five" — drawn here by Windows itself rather than by six, because a popup menu is the one piece of
/// chrome this front can have for free and have look native.
///
/// What it does *not* have is the Mac's editor: renaming, recolouring and deleting a profile are all
/// text fields and swatches, and this front has no control that can hold either. Adding one names
/// itself, from the same list of templates the Mac's colours come from.
extension RailWindow {
    private static let newProfileCommand: Int32 = 1000
    private static let privateProfileCommand: Int32 = 1001

    func showProfileMenu(below chip: RECT) {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }

        let profiles = model.profiles
        for (index, profile) in profiles.enumerated() {
            var flags = UINT(MF_STRING)
            if profile.id == model.activeProfile.id { flags |= UINT(MF_CHECKED) }
            _ = profile.name.withCString(encodedAs: UTF16.self) {
                AppendMenuW(menu, flags, UINT_PTR(index + 1), $0)
            }
        }
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        _ = "New profile".withCString(encodedAs: UTF16.self) {
            AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(Int(Self.newProfileCommand)), $0)
        }
        // The Mac's "Private Window" — a profile that is never written down, browsing in a
        // non-persistent store. Offered only while there is not one already, the way the Mac's
        // popover hides it once `browser.privateProfile` exists.
        if !profiles.contains(where: \.isPrivate) {
            _ = "Private".withCString(encodedAs: UTF16.self) {
                AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(Int(Self.privateProfileCommand)), $0)
            }
        }

        var point = POINT(x: chip.left, y: chip.bottom + px(4))
        ClientToScreen(hwnd, &point)
        // `TPM_RETURNCMD` hands the answer back here instead of posting `WM_COMMAND`, which keeps the
        // whole interaction in one function — see `SixRailTrackPopupMenu` for why the wrapper.
        let chosen = SixRailTrackPopupMenu(
            menu, UINT(TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RETURNCMD | TPM_NONOTIFY),
            point.x, point.y, hwnd
        )
        guard chosen != 0 else { return }

        if chosen == Self.newProfileCommand {
            model.addProfile()
        } else if chosen == Self.privateProfileCommand {
            model.selectPrivateProfile()
        } else if profiles.indices.contains(Int(chosen) - 1) {
            let profile = profiles[Int(chosen) - 1]
            guard profile.id != model.activeProfile.id else { return }
            model.selectProfile(profile.id)
        }

        // A profile change is a different strip, so everything that tracks the focused column has to
        // be told: the pages of the profile being left go out of sight (they are not destroyed — the
        // strip is still there to come back to), and the address bar is showing another profile's URL.
        for (id, view) in webViews where !model.columns.contains(where: { $0.id == id }) {
            view.setVisible(false)
        }
        addressBarShownTabID = nil
        invalidate()
    }
}
