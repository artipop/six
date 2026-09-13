import SwiftUI

/// The address field's note that the page offers tools to agents (WebMCP) — what Chrome shows on
/// its side, and the quickest way to see that a page's `registerTool` reached six at all. Nothing
/// when WebMCP is off or the page declares nothing, so it costs the bar no room on the pages that
/// don't, which is nearly all of them.
struct PageToolsButton: View {
    let tab: BrowserTab

    @Environment(WebMCPStore.self) private var webMCP
    @State private var showsList = false

    var body: some View {
        let tools = webMCP.tools(in: tab.id)
        if !tools.isEmpty {
            Button { showsList.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(verbatim: "\(tools.count)")
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Tools this page offers to agents")
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                PageToolsList(tools: tools)
            }
        }
    }
}

/// The list behind the badge. Names and descriptions as the page wrote them — they are the page's
/// words, and the one place a person can read what an agent is being offered before it is offered.
private struct PageToolsList: View {
    let tools: [WebMCPTool]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools this page offers to agents")
                .font(.headline)
            Text("Declared by the page through WebMCP. Agents reach them with list_page_tools and call_page_tool.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(verbatim: tool.name)
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                                if tool.readOnly { ToolHint(text: "read-only") }
                                if tool.consequential { ToolHint(text: "consequential") }
                            }
                            if !tool.title.isEmpty { Text(verbatim: tool.title) }
                            Text(verbatim: tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            if let origin = tools.first?.origin {
                Text(verbatim: origin)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// One of the page's annotations, as a word in a capsule. Only the two that change what a call
/// means: `untrustedContentHint` is about the answer, and the answer is already fenced as the
/// page's for whoever reads it.
private struct ToolHint: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
