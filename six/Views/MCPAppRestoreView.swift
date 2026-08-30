import SwiftUI

/// An app window that came back from the last launch, waiting to be asked again.
///
/// A browser re-fetches a page without asking anybody and refuses to re-submit a form without
/// asking. A tool call is the second kind: `search_flights` costs nothing to repeat and `book_seat`
/// costs a seat, and the only thing in the protocol that tells them apart is `readOnlyHint`. So a
/// read-only tool has already re-run by the time this is drawn, and everything else waits here.
struct MCPAppRestoreView: View {
    let tab: BrowserTab
    let saved: AppWindowSnapshot

    @Environment(MCPAppStore.self) private var apps
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(saved.toolTitle)
                .font(.headline)
            Text(saved.serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
            if arguments != "{}" {
                Text(arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Run Again", action: run)
                    .buttonStyle(.borderedProminent)
            }
            Text("six does not run a tool again by itself unless the server says it changes nothing.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        // Asking the server whether re-running is safe happens when the column is actually looked
        // at, not at launch: a strip of twenty restored apps would otherwise open twenty
        // connections before the first one is on screen. `examine` asks once per window.
        .task { apps.examine(tab, saved) }
    }

    /// The call as it was made, readably: `{"west":37.3,…}` with the braces off.
    private var arguments: String {
        let text = saved.toolArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 2 else { return "{}" }
        return String(text.dropFirst().dropLast())
    }

    private func run() {
        isRunning = true
        Task {
            await apps.rerun(saved, in: tab.id)
            isRunning = false
        }
    }
}
