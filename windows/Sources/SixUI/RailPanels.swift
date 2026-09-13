import CRailInterop
import Foundation
import SixBrowser
import WinSDK

/// The "⋯" at the end of the bar, and the two lists it opens.
///
/// The Linux front has History, Site Permissions and the overview as three toolbar buttons; a title
/// bar has no room for three more, and every Windows browser keeps exactly these things behind a
/// "⋯" in the same corner. The menu is Windows' own, like the profile menu beside it.
extension RailWindow {
    private static let historyCommand: Int32 = 2001
    private static let permissionsCommand: Int32 = 2002
    private static let overviewCommand: Int32 = 2003

    func showMoreMenu(below button: RECT) {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        func item(_ title: String, _ command: Int32, checked: Bool = false) {
            _ = title.withCString(encodedAs: UTF16.self) {
                AppendMenuW(menu, UINT(MF_STRING) | (checked ? UINT(MF_CHECKED) : 0), UINT_PTR(Int(command)), $0)
            }
        }
        // The tab puts the key in the menu's own accelerator column, the way Windows menus say it.
        item("History\tCtrl+H", Self.historyCommand)
        item("Site permissions", Self.permissionsCommand)
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        item("Overview\tAlt+O", Self.overviewCommand, checked: model.isOverview)

        // Right-aligned under the button, so the menu opens inward from the window's corner.
        var point = POINT(x: button.right, y: button.bottom + px(4))
        ClientToScreen(hwnd, &point)
        let chosen = SixRailTrackPopupMenu(
            menu, UINT(TPM_RIGHTALIGN | TPM_TOPALIGN | TPM_RETURNCMD | TPM_NONOTIFY),
            point.x, point.y, hwnd
        )
        switch chosen {
        case Self.historyCommand: showHistory()
        case Self.permissionsCommand: showSitePermissions()
        case Self.overviewCommand: toggleOverview()
        default: break
        }
    }

    /// History, over the same `visits` table the Mac writes and the same `HistoryStore` that reads
    /// it, scoped to the profile on screen. A row opens in a new window beside the one you are on —
    /// the Linux sheet's `+`, and what the Mac's does with ⌘.
    func showHistory() {
        let panel = RailListPanel(
            title: "History — \(model.activeProfile.name)",
            searchable: true,
            emptyText: model.activeProfile.isPrivate ? "A private profile keeps no history." : "Pages you visit will show up here.",
            hint: "Enter opens in a new window · Esc closes",
            rows: { [weak self] query in
                self?.model.history(matching: query).map {
                    RailListPanel.Row(id: $0.url, title: $0.title, detail: $0.detail)
                } ?? []
            },
            activate: { [weak self] row in
                guard let self else { return }
                model.openColumn(url: row.id)
                listPanel?.close()
                if let hwnd { SetForegroundWindow(hwnd) }
                invalidate()
            }
        )
        present(panel)
    }

    /// Every site that was ever answered about the camera or the microphone — the place to change an
    /// answer you are not standing on. The Mac's `PermissionsView`, over the same rows in the
    /// `settings` table. Answers given in a private profile are not listed: they were never written.
    func showSitePermissions() {
        let panel = RailListPanel(
            title: "Site permissions",
            searchable: false,
            emptyText: "When a site asks for the camera or the microphone, your answer is remembered here.",
            hint: "Delete forgets an answer · Esc closes",
            rows: { [weak self] _ in
                self?.model.permissionSites.map {
                    RailListPanel.Row(id: $0.id, title: $0.origin, detail: $0.detail)
                } ?? []
            },
            activate: nil,
            remove: { [weak self] row in self?.model.forgetPermissions(row.id) }
        )
        present(panel)
    }

    /// One list at a time: opening the other replaces it rather than stacking a second window on it.
    func present(_ panel: RailListPanel) {
        guard let hwnd else { return }
        listPanel?.close()
        listPanel = panel
        panel.onClose = { [weak self, weak panel] in
            guard let self, listPanel === panel else { return }
            listPanel = nil
        }
        if !panel.show(owner: hwnd) { listPanel = nil }
    }
}
