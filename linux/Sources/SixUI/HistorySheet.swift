import Adwaita
import Foundation
import SixBrowser

/// History, over the same `visits` table the Mac writes and the same `HistoryStore` that reads it.
///
/// The Mac's `HistoryView` is a sheet grouped by day with a search field; this is that, in adwaita's
/// terms. What it is *not* is a second implementation of history — the queries, the profile scoping
/// and the search all come from `SixCore`, and only the rows are drawn here.
struct HistorySheet: View {
    @Binding var visible: Bool
    @State private var query = ""
    /// The rows as they were last read. A search is a database query, not a filter over a list held
    /// in memory, so it is re-read when the text changes rather than recomputed on every render.
    ///
    /// Seeded rather than filled from `onAppear`, for the same reason the strip is: a state
    /// assignment made while the view is appearing has nowhere to land — the body was already
    /// evaluated with the old value. The sheet is built when it opens, so the seed is fresh.
    @State private var rows: [BrowserModel.HistoryRow] = BrowserModel.shared.history(matching: "")

    var model: BrowserModel { .shared }

    var view: Body {
        VStack {
            EntryRow("Search history", text: $query)
                .entryActivated { reload() }
                .padding(8)

            if rows.isEmpty {
                StatusPage(
                    query.isEmpty ? "Nothing here yet" : "Nothing found",
                    icon: .default(icon: .documentOpenRecent),
                    description: query.isEmpty
                        ? "Pages you visit will show up here."
                        : "No page in history matches “\(query)”."
                )
                .vexpand()
            } else {
                ScrollView {
                    List(rows, selection: nil) { row in
                        ActionRow(row.title.isEmpty ? row.url.absoluteString : row.title)
                            .subtitle(row.url.absoluteString)
                            .suffix {
                                Button(icon: .default(icon: .listAdd)) {
                                    model.open(row.url)
                                    visible = false
                                }
                                .flat()
                            }
                    }
                }
                .vexpand()
            }
        }
    }

    /// Ask the database, scoped to the profile, the way the Mac's sheet does.
    func reload() {
        rows = model.history(matching: query)
    }
}
