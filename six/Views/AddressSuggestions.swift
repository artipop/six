import SwiftUI

/// The rows under a field that takes both a query and an address — the start page's and the top
/// bar's, which used to be two different answers to one question: the start page offered history,
/// saved pages and the engine's completions, and the address field offered nothing at all.
///
/// Four sources, in the order they are trusted:
///
/// 1. **The address**, when the input looks like one — Enter should open `apple.com`, not search for it.
/// 2. **Saved pages.** A page you bookmarked is one you decided to keep. Two kinds of match, and they
///    are not redundant: `BookmarkStore.suggest` is the letters (`git` → the GitHub page, from the
///    first key and with no model loaded), `PersonalSuggestions` is the meaning («плов» → the English
///    recipe), which only speaks up at three letters and never for an address.
/// 3. **History** — a page you happened to open, or a query you searched before (`HistoryStore.suggest`).
/// 4. **The engine's completions** — what other people are typing, and the only one of the four that
///    leaves the Mac.
///
/// A private window gets the first and the last only: it searches nothing of yours, and a field that
/// answered with your bookmarks would be handing back the one thing that window was opened to leave
/// behind. Its own history is empty by construction.
@MainActor
@Observable
final class AddressSuggestions {
    let engine = SearchSuggestions()
    let personal = PersonalSuggestions()

    /// Sources that answer asynchronously are started here; the local ones are read in `rows`.
    func update(for text: String, context: Context) {
        engine.update(for: text)
        guard !context.isPrivate else { return personal.clear() }
        personal.update(for: text, in: context.bookmarks, scope: context.scope, profileID: context.profileID)
    }

    func clear() {
        engine.clear()
        personal.clear()
    }

    /// Where the rows are read from, and whose window is asking.
    struct Context {
        let history: HistoryStore
        let bookmarks: BookmarkStore
        let scope: BookmarkScope
        let profileID: Profile.ID
        let isPrivate: Bool
        let searchEngine: SearchEngine
    }

    nonisolated struct Limits {
        var saved = 3
        var history = 4
        /// The whole list, however it is made up.
        var rows = 10
    }

    func rows(for text: String, context: Context, limits: Limits = Limits()) -> [Row] {
        var rows: [Row] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field has nothing under it: erasing what was typed, or Esc, is how the list is put away.
        guard !trimmed.isEmpty else { return [] }
        if URL.looksLikeAddress(trimmed) { rows.append(Row(text: trimmed, kind: .address)) }
        if !context.isPrivate {
            var savedURLs = Set<URL>()
            // The letters first: a title that starts with what you typed is the stronger evidence,
            // and it is on screen a keystroke before the vectors can answer.
            let literal = context.bookmarks.suggest(trimmed, in: context.scope, profileID: context.profileID, limit: limits.saved)
                .map { Row(text: $0.displayTitle, detail: $0.displayDetail, kind: .saved($0.url)) }
            // The passage the vectors actually matched goes in the tooltip: the row says which page,
            // and hovering says why it is being offered.
            let meant = personal.hits.map { hit in
                Row(text: hit.bookmark.displayTitle, detail: hit.bookmark.displayDetail,
                    note: hit.snippet.isEmpty ? nil : hit.snippet, kind: .saved(hit.bookmark.url))
            }
            for row in literal + meant where savedURLs.count < limits.saved {
                if case .saved(let url) = row.kind, savedURLs.insert(url).inserted { rows.append(row) }
            }
            // A page that is both saved and visited is one row, the saved one — it is the row that
            // knows what the page is about.
            rows += context.history.suggest(trimmed, in: context.profileID, limit: limits.history)
                .filter { !savedURLs.contains($0.url) }
                .map(Self.row)
        }
        let shown = Set(rows.map { $0.text.lowercased() })
        // Whatever room is left after the local sources. The engine offers eight; a list of sixteen
        // rows under a field is not a list any more.
        rows += engine.items
            .filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame && !shown.contains($0.lowercased()) }
            .prefix(max(0, limits.rows - rows.count))
            .map { Row(text: $0, detail: String(localized: "\(context.searchEngine.title) Search"), kind: .search) }
        return Array(rows.prefix(limits.rows))
    }

    /// A results page is shown as the query it was, with where it went — like Chrome does.
    private static func row(_ entry: Visit) -> Row {
        if let search = SearchEngine.search(from: entry.url) {
            return Row(text: search.query, detail: String(localized: "\(search.engine.title) Search"), kind: .history(entry.url))
        }
        return Row(text: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                   detail: entry.url.host() ?? entry.url.absoluteString,
                   kind: .history(entry.url))
    }

    struct Row {
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

        /// Opens the row in `tab`: a page it names is loaded as it was, anything else is typed input.
        func open(in tab: BrowserTab) {
            switch kind {
            case .history(let url), .saved(let url): tab.load(url)
            case .address, .search: tab.navigate(to: text)
            }
        }
    }
}

/// The list itself, drawn the same under both fields; only the type size differs.
struct SuggestionList: View {
    let rows: [AddressSuggestions.Row]
    @Binding var selection: Int?
    let accent: Color
    var compact = false
    let open: (AddressSuggestions.Row) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let picked = index == selection
                HStack(spacing: compact ? 8 : 10) {
                    Image(systemName: row.symbol)
                        .font(.caption)
                        .frame(width: 14)
                        .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    Text(row.text)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(compact ? .caption : .callout)
                            .lineLimit(1)
                            .foregroundStyle(picked ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .background(picked ? AnyShapeStyle(accent) : AnyShapeStyle(.clear))
                .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
                .help(row.note ?? "")
                .onTapGesture { open(row) }
                #if os(macOS)
                .onHover { if $0 { selection = index } }
                #endif
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous).strokeBorder(.separator) }
    }
}
