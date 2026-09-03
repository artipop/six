import SwiftUI

/// What a fresh window shows instead of somebody's home page: one field that takes both a query and
/// an address, with completions underneath. Native, so it gets real keyboard handling and the
/// profile's colour — and so the first thing a new window does isn't a network request.
struct StartPage: View {
    let tab: BrowserTab
    /// The field only grabs the keyboard in the focused window of the current workspace.
    let isActive: Bool

    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks
    @State private var text = ""
    @State private var selection: Int?
    @State private var suggestions = SearchSuggestions()
    /// The rows that came from what this person saved, not from what everybody is typing.
    @State private var personal = PersonalSuggestions()
    @FocusState private var fieldFocused: Bool
    @Environment(SettingsStore.self) private var settings
    /// From settings, not a local copy: every other start page redraws when this one switches engines.
    private var engine: SearchEngine { settings.searchEngine }

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    private static let historyLimit = 4
    /// The whole list, however it is made up: four sources under one field, and a screenful is ten.
    private static let rowLimit = 10

    /// The address row comes first when the input looks like one — Enter should open `apple.com`,
    /// not search for it. Then the **saved pages that match by meaning**, then pages from the
    /// profile's history, then the engine's completions.
    ///
    /// Saved above visited above guessed, and that order is the argument. A page you bookmarked is
    /// one you decided to keep; a page in history is one you happened to open; a completion is what
    /// other people are typing. The first two are on this Mac and cost nothing to ask
    /// (`PersonalSuggestions`, `HistoryStore.suggest`); the third is a query leaving the machine.
    private var rows: [Row] {
        var rows: [Row] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL.looksLikeAddress(trimmed) { rows.append(Row(text: trimmed, kind: .address)) }
        if !trimmed.isEmpty {
            rows += personal.hits.map { hit in
                Row(text: hit.bookmark.displayTitle,
                    detail: hit.bookmark.displayDetail,
                    // The passage the vectors actually matched, in the tooltip: the row says which
                    // page, and hovering says why it is being offered.
                    note: hit.snippet.isEmpty ? nil : hit.snippet,
                    kind: .saved(hit.bookmark.url))
            }
            // A page that is both saved and visited is one row, the saved one — it is the row that
            // knows what the page is about.
            let saved = Set(personal.hits.map { $0.bookmark.url })
            rows += browser.history.suggest(trimmed, in: tab.profileID, limit: Self.historyLimit)
                .filter { !saved.contains($0.url) }
                .map { entry in
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
        // Whatever room is left after the two local sources. The engine offers eight; a list of
        // sixteen rows under a field is not a list any more.
        rows += suggestions.items
            .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame && !shown.contains($0.lowercased()) }
            .prefix(max(0, Self.rowLimit - rows.count))
            .map { Row(text: $0, detail: String(localized: "\(engine.title) Search"), kind: .search) }
        return rows
    }

    /// Where the name and the field stand, as a share of the window's height rather than a number of
    /// points — the rest of six sizes itself that way, and a start page is a page.
    private static let restingHeight = 0.32
    /// What the name, the field and a full list want under them, in points, because that is what a
    /// font is measured in. In a window too short for both, the field gives up its share of the
    /// height rather than the list going off the bottom edge.
    private static let contentHeight: CGFloat = 480

    private func topInset(_ height: CGFloat) -> CGFloat {
        min(height * Self.restingHeight, max(24, height - Self.contentHeight))
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
            // The stack hangs from a fixed point near the top instead of being centred, and that is
            // the whole reason for the geometry reader. Centred, the field moved every time the list
            // under it changed height: a row arrives from the engine and the thing you are typing
            // into jumps upward under the caret. The list is the only part that may grow, and it
            // grows downward into the empty half of the page, where there is room for it.
            GeometryReader { geometry in
                VStack(spacing: 14) {
                    Text("six")
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .foregroundStyle(accent)
                    field
                    list
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, topInset(geometry.size.height))
            }
        }
        .background(.background)
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { return }
            fieldFocused = true
            // The rows below the field are answered by a model that takes seconds to load, and a
            // start page taking the keyboard is the earliest honest sign that a question is coming.
            // Not in a private window, which searches nothing of yours anyway (`updatePersonal`).
            if !browser.isPrivate(tab.profileID) {
                bookmarks.warmUpEmbedder(in: settings.bookmarkScope, profileID: tab.profileID)
            }
        }
        .onChange(of: text) { _, value in
            selection = nil
            suggestions.update(for: value)
            updatePersonal(value)
        }
        .onChange(of: engine) { _, _ in suggestions.update(for: text) }
        .onChange(of: settings.bookmarkScope) { _, _ in updatePersonal(text) }
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
                    clearSuggestions()
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
                    .help(row.note ?? "")
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

    /// A window in a private profile searches nothing of yours: the star is off there, no page is
    /// saved from there, and a field that answered with your bookmarks would be handing back the one
    /// thing that window was opened to leave behind.
    private func updatePersonal(_ value: String) {
        guard !browser.isPrivate(tab.profileID) else { return personal.clear() }
        personal.update(for: value, in: bookmarks, scope: settings.bookmarkScope, profileID: tab.profileID)
    }

    private func clearSuggestions() {
        suggestions.clear()
        personal.clear()
    }

    private func open(_ row: Row) {
        switch row.kind {
        case .history(let url), .saved(let url):
            clearSuggestions()
            tab.load(url)
        case .address, .search:
            open(row.text)
        }
    }

    private func open(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        clearSuggestions()
        tab.navigate(to: input)
    }

    private struct Row {
        enum Kind { case address, saved(URL), history(URL), search }
        let text: String
        var detail: String? = nil
        /// The tooltip — what a row knows that doesn't fit on it. Only the saved rows have one.
        var note: String? = nil
        let kind: Kind

        var symbol: String {
            switch kind {
            case .address: "arrow.up.right"
            case .saved: "bookmark.fill"
            case .history: "clock"
            case .search: "magnifyingglass"
            }
        }
    }
}
