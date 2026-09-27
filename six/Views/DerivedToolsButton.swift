#if os(macOS)
import SwiftUI

/// Beside the WebMCP wrench, for a page that declared no tools: the wrench with a spark, when its
/// accessibility tree is good enough to make tools of (`DerivedPageTools`). Only with WebMCP on
/// and six allowed under Accessibility; nothing is asked for to show it. `AddressBar` holds the
/// reading, since a view that draws nothing never runs a task.
struct DerivedToolsButton: View {
    let tab: BrowserTab
    let derived: DerivedPageTools?

    @Environment(WebMCPStore.self) private var webMCP
    @State private var showsList = false

    var body: some View {
        if let derived, derived.verdict == .good, webMCP.tools(in: tab.id).isEmpty {
            Button { showsList.toggle() } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 6, weight: .bold))
                            .offset(x: 4, y: -3)
                    }
            }
            .foregroundStyle(.secondary)
            .help(Text("Tools derived from the page: \(derived.tools.count)"))
            .buttonStyle(.borderless)
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                DerivedToolsList(derived: derived)
            }
        }
    }

    static func assess(_ tab: BrowserTab) async -> DerivedPageTools? {
        // Past the first layout and the scripts that run on load.
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let placed = await AccessibilityOverlay.shared.assess(tab) else { return nil }
        return DerivedPageTools(placed.nodes)
    }
}

private struct DerivedToolsList: View {
    let derived: DerivedPageTools

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools derived from the page")
                .font(.headline)
            Text("From the accessibility tree of the part on screen. Not offered to agents yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(derived.tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: tool.verb)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: tool.name).lineLimit(1)
                            }
                            if !tool.inputs.isEmpty {
                                Text(verbatim: tool.inputs.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            Text("\(derived.named) of \(derived.actionable) controls named")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Show Accessibility Overlay") { AccessibilityOverlay.shared.isOn = true }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}

private extension DerivedPageTools.Tool {
    /// The verbs of the overlay and of `get_accessibility_tree`, so the three read alike.
    var verb: String {
        switch kind {
        case .form: "fill"
        case .press: "press"
        case .type: "type"
        }
    }
}
#endif
