import AppKit
import SwiftUI

/// ⌘Y: the selected profile's history, searchable, grouped by day. A click opens the page in a new
/// window of the strip; ⌫ forgets the row.
struct HistoryView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var profile: Profile { browser.selectedProfile }
    private var results: [HistoryEntry] { browser.history.search(query, in: profile.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(profile.color).frame(width: 10, height: 10)
                Text("\(profile.name) History").font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($searchFocused)
                    .onSubmit(openSelectedOrFirst)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No History" : "No Matches", systemImage: "clock.arrow.circlepath")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.day) { group in
                        Section(group.label) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry)
                                    .tag(entry.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { open(entry) }
                                    .contextMenu {
                                        Button("Open in New Window") { open(entry) }
                                        Button("Copy Address") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
                                        }
                                        Divider()
                                        Button("Forget", role: .destructive) { browser.history.remove(entry.id) }
                                    }
                            }
                        }
                    }
                }
                .onDeleteCommand { if let selection { browser.history.remove(selection) } }
                .onKeyPress(.return) { openSelectedOrFirst(); return .handled }
            }
            Divider()
            HStack {
                Text("\(results.count) visits").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear \(profile.name) History…", role: .destructive) { confirmClear = true }
                    .disabled(browser.history.entries(in: profile.id).isEmpty)
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .onAppear { searchFocused = true }
        .clearHistoryDialog(isPresented: $confirmClear)
    }

    /// Relative to the screen, like the layout — a fixed point size is tiny on a 5K panel.
    private var sheetSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: (screen.width * 0.38).rounded(), height: (screen.height * 0.62).rounded())
    }

    private struct DayGroup {
        let day: Date
        let label: String
        let entries: [HistoryEntry]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var order: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in results {
            let day = calendar.startOfDay(for: entry.visitedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { day in
            let label = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : formatter.string(from: day)
            return DayGroup(day: day, label: label, entries: byDay[day] ?? [])
        }
    }

    private func openSelectedOrFirst() {
        if let selection, let entry = results.first(where: { $0.id == selection }) {
            open(entry)
        } else if let first = results.first {
            open(first)
        }
    }

    private func open(_ entry: HistoryEntry) {
        browser.newTab(url: entry.url, in: entry.profileID)
        dismiss()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.visitedAt, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle).lineLimit(1)
                Text(entry.displayDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

extension FocusedValues {
    @Entry var showHistory: FocusAddressBarAction?
}
