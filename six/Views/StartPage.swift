import SwiftUI

/// What a fresh window shows instead of somebody's home page: one field that takes both a query and
/// an address, with completions underneath. Native, so it gets real keyboard handling and the
/// profile's colour — and so the first thing a new window does isn't a network request.
struct StartPage: View {
    let tab: BrowserTab
    /// The field only grabs the keyboard in the focused window of the current workspace.
    let isActive: Bool

    @Environment(BrowserState.self) private var browser
    @State private var text = ""
    @State private var selection: Int?
    @State private var suggestions = SearchSuggestions()
    @FocusState private var fieldFocused: Bool
    @Environment(SettingsStore.self) private var settings
    /// From settings, not a local copy: every other start page redraws when this one switches engines.
    private var engine: SearchEngine { settings.searchEngine }

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    private static let historyLimit = 4

    /// The address row comes first when the input looks like one — Enter should open `apple.com`,
    /// not search for it. Then pages from the profile's history, then the engine's completions.
    private var rows: [Row] {
        var rows: [Row] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL.looksLikeAddress(trimmed) { rows.append(Row(text: trimmed, kind: .address)) }
        if !trimmed.isEmpty {
            rows += browser.history.suggest(trimmed, in: tab.profileID, limit: Self.historyLimit).map { entry in
                // A results page is shown as the query it was, with where it went — like Chrome does.
                if let search = SearchEngine.search(from: entry.url) {
                    return Row(text: search.query, detail: String(localized: "\(search.engine.title) Search"), kind: .history(entry.url))
                }
                return Row(text: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                           detail: entry.url.host() ?? entry.url.absoluteString,
                           kind: .history(entry.url))
            }
        }
        let shown = Set(rows.map { $0.text.lowercased() })
        rows += suggestions.items
            .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame && !shown.contains($0.lowercased()) }
            .map { Row(text: $0, detail: String(localized: "\(engine.title) Search"), kind: .search) }
        return rows
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Text("six")
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .foregroundStyle(accent)
                field
                list
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.bottom, 90) // a touch above centre, where the eye lands
        }
        .background(.background)
        .onChange(of: isActive, initial: true) { _, active in
            if active { fieldFocused = true }
        }
        .onChange(of: text) { _, value in
            selection = nil
            suggestions.update(for: value)
        }
        .onChange(of: engine) { _, _ in suggestions.update(for: text) }
    }

    private var field: some View {
        HStack(spacing: 10) {
            enginePicker
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit {
                    if let selection, rows.indices.contains(selection) { open(rows[selection]) } else { open(text) }
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    suggestions.clear()
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(fieldFocused ? AnyShapeStyle(accent) : AnyShapeStyle(.separator), lineWidth: fieldFocused ? 2 : 1) }
    }

    /// Which engine answers the field, in the one place where it matters — next to the field.
    private var enginePicker: some View {
        @Bindable var settings = settings
        return Menu {
            Picker("Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text(engine.title)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where a query goes, and where the suggestions come from")
    }

    @ViewBuilder
    private var list: some View {
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let picked = index == selection
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol)
                            .font(.caption)
                            .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        Text(row.text)
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.callout)
                                .lineLimit(1)
                                .foregroundStyle(picked ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(picked ? AnyShapeStyle(accent) : AnyShapeStyle(.clear))
                    .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .contentShape(Rectangle())
                    .onTapGesture { open(row) }
                    .onHover { if $0 { selection = index } }
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator) }
            .transition(.opacity)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let next = (selection ?? -1) + delta
        selection = next < 0 ? nil : min(next, rows.count - 1)
        return .handled
    }

    private func open(_ row: Row) {
        if case .history(let url) = row.kind {
            suggestions.clear()
            tab.load(url)
        } else {
            open(row.text)
        }
    }

    private func open(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        suggestions.clear()
        tab.navigate(to: input)
    }

    private struct Row {
        enum Kind { case address, history(URL), search }
        let text: String
        var detail: String? = nil
        let kind: Kind

        var symbol: String {
            switch kind {
            case .address: "arrow.up.right"
            case .history: "clock"
            case .search: "magnifyingglass"
            }
        }
    }
}
