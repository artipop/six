import Adwaita
import Foundation
import SixBrowser

/// Saved pages, over the same `bookmarks` table the Mac writes.
///
/// The Mac's sheet searches the readable text of every saved page with vectors; this searches the
/// title and the address. That is the honest difference, and it is the one the phase boundary drew —
/// the readable copy and the embeddings were put outside it, not the record.
struct BookmarksSheet: View {
    @Binding var visible: Bool
    @State private var query = ""
    @State private var rows: [BrowserModel.BookmarkRow] = BrowserModel.shared.bookmarks(matching: "")

    var model: BrowserModel { .shared }

    var view: Body {
        VStack {
            EntryRow("Search bookmarks", text: $query)
                .entryActivated { reload() }
                .padding(8)

            if rows.isEmpty {
                StatusPage(
                    query.isEmpty ? "No bookmarks yet" : "Nothing found",
                    icon: .default(icon: .userBookmarks),
                    description: query.isEmpty
                        ? "Save the page you are on with the star."
                        : "No saved page matches “\(query)”."
                )
                .vexpand()
            } else {
                ScrollView {
                    List(rows, selection: nil) { row in
                        ActionRow(row.title)
                            .subtitle(row.site)
                            .suffix {
                                Button(icon: .default(icon: .listAdd)) {
                                    model.open(row.url)
                                    visible = false
                                }
                                .flat()
                                Button(icon: .default(icon: .userTrash)) {
                                    model.removeBookmark(row.id)
                                    reload()
                                }
                                .flat()
                            }
                    }
                }
                .vexpand()
            }
        }
    }

    func reload() { rows = model.bookmarks(matching: query) }
}
