import SwiftUI

/// The question a site asks, drawn where the answer belongs: in the column that asked, under its own
/// title bar.
///
/// Deliberately not a sheet. A sheet belongs to the app, and in a strip of twenty windows the page
/// that wants the camera is one column of twenty — stopping the other nineteen to answer for it
/// would be a browser mistaking a page for itself. The bar pushes the page down instead of covering
/// it, which also keeps it out of the reach of the problem in `HostedOverlay`: it is a sibling of the
/// web view in the stack, not something drawn over it, so its buttons see the mouse.
struct PermissionBar: View {
    let tab: BrowserTab
    let question: SitePermissions.Question

    @Environment(SitePermissions.self) private var permissions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: question.permissions.first?.symbol ?? "video")
                .foregroundStyle(.tint)
            Text("\(question.host) wants to use your \(devices).")
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Block") { permissions.answer(false, for: tab.id) }
            Button("Allow") { permissions.answer(true, for: tab.id) }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thickMaterial)
        // Every question gets its own transition: two questions in a row from the same site would
        // otherwise look like one bar that never went away.
        .id(question.id)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// "camera and microphone" — joined the way the reader's language joins a list.
    private var devices: String {
        ListFormatter.localizedString(byJoining: question.permissions.map(\.label))
    }
}
