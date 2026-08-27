import AppKit
import SwiftUI

/// The filter lists, what each one costs, and the sites left alone. Opened from the Privacy menu or
/// from the shield in a window's address field.
struct BlockingView: View {
    @Environment(ContentBlocker.self) private var blocker
    @Environment(\.dismiss) private var dismiss
    @State private var newListAddress = ""

    var body: some View {
        @Bindable var blocker = blocker
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                Text("Content Blocking").font(.headline)
                Spacer()
                if blocker.isWorking { ProgressView().controlSize(.small) }
                Toggle("Block Ads and Trackers", isOn: $blocker.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Off means off: nothing is fetched, compiled or attached to a page")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            List {
                Section("Filter Lists") {
                    ForEach(blocker.lists) { list in
                        FilterListRow(list: list, status: blocker.status[list.id])
                            .contextMenu {
                                if !list.isBuiltIn {
                                    Button("Remove List", role: .destructive) { blocker.removeList(list.id) }
                                }
                                Button("Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(list.source.absoluteString, forType: .string)
                                }
                            }
                    }
                    HStack(spacing: 8) {
                        TextField("Add a list by address", text: $newListAddress)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addList)
                        Button("Add", action: addList)
                            .disabled(URL(string: newListAddress.trimmingCharacters(in: .whitespaces))?.host() == nil)
                    }
                    .padding(.vertical, 2)
                }

                Section("Sites Left Alone") {
                    if blocker.allowlist.isEmpty {
                        Text("No sites. The shield in a window's address field allows the site it is showing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(blocker.allowlist.sorted(), id: \.self) { host in
                            HStack {
                                Image(systemName: "shield.slash").foregroundStyle(.secondary)
                                Text(host)
                                Spacer()
                                Button {
                                    if let url = URL(string: "https://\(host)") { blocker.setAllowed(false, for: url) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Block ads on \(host) again")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .disabled(!blocker.isEnabled)

            Divider()
            HStack {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Update Now") { Task { await blocker.updateNow() } }
                    .controlSize(.small)
                    .disabled(!blocker.isEnabled || blocker.isWorking)
            }
            .padding(10)
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
    }

    private var footnote: String {
        guard blocker.isEnabled else { return "Blocking is off — nothing is fetched or attached to a page." }
        let ready = blocker.lists.filter { blocker.status[$0.id]?.isReady == true }
        let rules = ready.reduce(0) { $0 + (blocker.status[$1.id]?.rules ?? 0) }
        guard rules > 0 else { return "Preparing filter lists…" }
        return "\(ready.count) \(ready.count == 1 ? "list" : "lists") blocking, \(rules.formatted()) rules"
    }

    private func addList() {
        let text = newListAddress.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), url.host() != nil else { return }
        blocker.addList(source: url, title: "")
        newListAddress = ""
    }

    /// Relative to the screen, like the rest of the layout.
    private var sheetSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: (screen.width * 0.36).rounded(), height: (screen.height * 0.58).rounded())
    }
}

private struct FilterListRow: View {
    @Environment(ContentBlocker.self) private var blocker
    let list: FilterList
    let status: ContentBlocker.Status?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { blocker.setEnabled($0, forListID: list.id) }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title)
                if !list.detail.isEmpty {
                    Text(list.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(state).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if case .updating = status?.phase { ProgressView().controlSize(.small) }
            if case .compiling = status?.phase { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }

    private var state: String {
        guard list.isEnabled else { return "Off" }
        switch status?.phase {
        case .updating: return "Updating…"
        case .compiling: return "Compiling…"
        case .failed(let message): return "Last update failed: \(message)"
        default: break
        }
        guard let status, status.isReady else { return "Waiting" }
        var line = "\(status.rules.formatted()) rules"
        if status.dropped > 0 { line += ", \(status.dropped.formatted()) over WebKit's limit" }
        if let updatedAt = status.updatedAt {
            line += " · updated \(updatedAt.formatted(.relative(presentation: .named)))"
        }
        return line
    }
}

extension FocusedValues {
    @Entry var showFilterLists: FocusAddressBarAction?
}
