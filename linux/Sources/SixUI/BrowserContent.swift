import Adwaita
import Foundation
import SixBrowser
import SixWebKit

/// The browser, declaratively. One window, always — what look like tabs are columns in the strip
/// inside it, which is the whole niri idea and the same constraint the Mac has.
public struct BrowserContent: View {
    /// The model. `NiriLayout` is shared with the Mac untouched; everything here reads it and puts
    /// widgets where it says.
    /// The model is a reference type holding `NiriLayout`, and a declarative front only re-renders
    /// when state is *assigned*. So the view keeps the derived list and reassigns it after anything
    /// that could change it. Crude, and exactly the tax a declarative layer charges for owning the
    /// update cycle — the alternative is the model pushing changes, which is next.
    @State private var model = BrowserModel()
    @State private var columns: [BrowserModel.Column] = []
    @State private var typed = ""

    public init() {}

    public var view: Body {
        VStack {
            toolbar
            strip
                .vexpand()
        }
        .onAppear {
            model.start()
            refresh()
        }
    }

    // MARK: The chrome

    @ViewBuilder var toolbar: Body {
        HStack {
            Button(icon: .default(icon: .goPrevious)) { model.goBack(); refresh() }
                .flat()
                .insensitive(!model.canGoBack)
            Button(icon: .default(icon: .goNext)) { model.goForward(); refresh() }
                .flat()
                .insensitive(!model.canGoForward)
            Button(icon: .default(icon: .viewRefresh)) { model.reload(); refresh() }
                .flat()
            EntryRow("Address", text: $typed)
                .onSubmit { model.go(to: typed); refresh() }
                .hexpand()
            Button(icon: .default(icon: .listAdd)) { model.openColumn(); refresh() }
                .flat()
        }
        .padding(6)
        .style("toolbar")
    }

    /// Pull the strip's shape out of the model and hand it to the view tree.
    func refresh() { columns = model.columns }

    // MARK: The strip

    var strip: Body {
        [
            ColumnStrip(columns: columns.map { column in
                (
                    id: column.id,
                    frame: column.frame,
                    content: self.columnView(column)
                )
            })
        ]
    }

    /// A column is its title bar and its page — `WindowChrome` on the Mac.
    @ViewBuilder func columnView(_ column: BrowserModel.Column) -> Body {
        VStack {
            Text(column.title.isEmpty ? "Untitled" : column.title)
                .ellipsize()
                .padding(4)
                .style(column.isFocused ? "heading" : "dim-label")
            WebView(url: column.url, session: model.session)
                .onTitleChange { model.setTitle($0, for: column.id); refresh() }
                .onURLChange { model.setURL($0, for: column.id); refresh() }
                .onFinishLoad { model.didFinishLoad($0, title: $1, for: column.id); refresh() }
                .vexpand()
        }
        .style("card")
    }
}
