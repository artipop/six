import SwiftUI

/// "Close tabs you have moved on from?" — the tabs `TabCleaner` found, each with its own checkbox.
struct TabCleanupSheet: ViewModifier {
    @Environment(BrowserState.self) private var browser

    func body(content: Content) -> some View {
        @Bindable var cleaner = browser.cleaner
        content.sheet(item: $cleaner.proposal) { proposal in
            TabCleanupList(proposal: proposal)
        }
    }
}

private struct TabCleanupList: View {
    let proposal: TabCleaner.Proposal

    @Environment(BrowserState.self) private var browser
    @State private var kept: Set<UUID> = []

    var body: some View {
        let tabs = browser.cleaner.stillOffered(in: browser)
        let closing = tabs.map(\.id).filter { !kept.contains($0) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Close tabs you have moved on from?")
                .font(.headline)
            Text(TabCleaner.unopened(days: proposal.days))
                .font(.callout)
                .foregroundStyle(.secondary)
            List(tabs) { tab in
                Toggle(isOn: Binding(
                    get: { !kept.contains(tab.id) },
                    set: { close in if close { kept.remove(tab.id) } else { kept.insert(tab.id) } }
                )) {
                    HStack(spacing: 8) {
                        TabMark(tab: tab)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title.isEmpty ? (tab.currentURL?.absoluteString ?? "") : tab.title)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(tab.currentURL?.host() ?? "")
                                Text(verbatim: "·")
                                Text(tab.seenAt, format: .relative(presentation: .named))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered)
            .frame(minHeight: 160, idealHeight: min(CGFloat(tabs.count) * 44 + 8, 360), maxHeight: 360)
            HStack {
                Spacer()
                Button("Close \(closing.count) Tabs") {
                    browser.cleaner.proposal = nil
                    browser.closeTabs(closing)
                }
                .disabled(closing.isEmpty)
                // It comes unasked, often mid-typing: Return must not close anything.
                Button("Keep All", role: .cancel) { browser.cleaner.proposal = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: tabs.isEmpty) { _, empty in if empty { browser.cleaner.proposal = nil } }
    }
}

extension View {
    func tabCleanupSheet() -> some View {
        modifier(TabCleanupSheet())
    }
}
