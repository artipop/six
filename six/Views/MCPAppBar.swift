import SwiftUI

/// An app asking to call one of its server's tools, drawn where the answer belongs: over the app's
/// own column, above the app itself.
///
/// The same arrangement as `PermissionBar`, and for the same reasons — a sibling of the web view in
/// the column's stack rather than a sheet, so the other nineteen windows of the strip are not
/// stopped to answer for this one, and so the buttons see the mouse.
///
/// Asked once per tool. The answer holds for the life of the window: see
/// `MCPAppSession.ToolRequest`.
struct MCPAppBar: View {
    let session: MCPAppSession
    let request: MCPAppSession.ToolRequest

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.tint)
            Text("\(session.title) wants to run \(request.tool.display) on \(session.server.name).")
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Block") { session.answerToolRequest(false) }
            Button("Allow") { session.answerToolRequest(true) }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thickMaterial)
        .id(request.id)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
