import Adwaita
import Foundation
import SixBrowser

/// Every site that was ever answered about the camera or the microphone — the place to change an
/// answer you are not standing on. The Mac's `PermissionsView`, in adwaita's terms and over the same
/// rows: the answers live in the `settings` table, so a site allowed here is allowed there.
///
/// Answers given in a private profile are not listed, because they were never written down.
struct PermissionsSheet: View {
    @Binding var visible: Bool
    /// Seeded rather than filled from `onAppear` — a state assignment made while a view is appearing
    /// has nowhere to land, and the sheet is built when it opens.
    @State private var rows: [BrowserModel.PermissionRow] = BrowserModel.shared.permissionSites

    var model: BrowserModel { .shared }

    var view: Body {
        VStack {
            if rows.isEmpty {
                StatusPage(
                    "No Sites Yet",
                    icon: .default(icon: .cameraDisabled),
                    description: "When a site asks for the camera or the microphone, your answer is remembered here."
                )
                .vexpand()
            } else {
                ScrollView {
                    List(rows, selection: nil) { row in
                        ActionRow(row.origin)
                            .subtitle(row.detail)
                            .suffix {
                                Button(icon: .default(icon: .userTrash)) {
                                    model.forgetPermissions(row.id)
                                    rows = model.permissionSites
                                }
                                .flat()
                                .tooltip("Ask again next time")
                            }
                    }
                }
                .vexpand()
            }
        }
    }
}
