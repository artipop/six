import Adwaita
import Foundation
import SixBrowser
import SixWebKit

/// The browser, declaratively. One window, always — what look like tabs are columns in the strip
/// inside it, which is the whole niri idea and the same constraint the Mac has.
public struct BrowserContent: View {
    /// The model. `NiriLayout` is shared with the Mac untouched; everything here reads it and puts
    /// widgets where it says.
    /// Only value types live in `@State`: Meta reflects over a view's stored properties to find it,
    /// and a class in there takes the runtime down. The model is `BrowserModel.shared`.
    ///
    /// The strip's shape is kept here and reassigned after anything that could change it — a
    /// declarative front re-renders on assignment, and the model is a reference type that mutates
    /// quietly. That is the tax this layer charges for owning the update cycle.
    /// A counter, not the data. The strip reads `model.columns` directly on every render; this only
    /// exists to *ask* for a render, and it is bumped from user actions — never from inside the
    /// render path. Assigning derived state during a render is what sent the view tree into
    /// unbounded recursion and took the stack with it.
    @State private var revision = 0
    @State private var typed = ""

    private var model: BrowserModel { .shared }

    public init() {}

    public var view: Body {
        VStack {
            toolbar
            strip
                .vexpand()
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

    /// Ask for a render. Safe from an action, never called while one is in progress.
    func refresh() { revision += 1 }

    // MARK: The strip

    /// The strip is a row of columns with gaps between them, which is what a horizontal box already
    /// is — so it is one, inside a scroll view, driven by `ForEach`.
    ///
    /// The first attempt was a `GtkFixed` container of my own, placing columns at the absolute
    /// x-positions `columnFrames()` computes. It crashed adwaita from the inside: managing
    /// `ViewStorage.content` by hand means removing children Meta still holds, and the corruption
    /// surfaced somewhere else entirely — in `Button.update`. `ForEach` is their machinery for
    /// children that come and go, it is what their own dynamic lists use, and it is not mine to
    /// re-implement. Absolute placement comes back when the overview needs a `GskTransform`; it is
    /// not needed to lay a row out.
    @ViewBuilder var strip: Body {
        ScrollView {
            HStack(spacing: Int(gap)) {
                ForEach(model.columns) { column in
                    columnView(column)
                }
            }
            .padding(Int(gap))
        }
    }

    /// Gaps are a fraction of the viewport, never a point constant — the same rule `NiriLayout`
    /// keeps, so the strip looks the same on a laptop and on a 5K panel.
    var gap: Double { model.gap }

    /// A column is its title bar and its page — `WindowChrome` on the Mac.
    @ViewBuilder func columnView(_ column: BrowserModel.Column) -> Body {
        VStack {
            Text(column.title.isEmpty ? "Untitled" : column.title)
                .ellipsize()
                .padding(4)
                .style(column.isFocused ? "heading" : "dim-label")
            page(for: column)
                .frame(
                    minWidth: Int(model.columnSize.width),
                    minHeight: Int(model.columnSize.height)
                )
                .vexpand()
        }
        .style("card")
    }

    /// Built as a value first: the page's own modifiers belong to `WebView`, and a `Body` has none
    /// of them.
    func page(for column: BrowserModel.Column) -> WebView {
        WebView(url: column.url, session: model.session)
            .onTitleChange { model.setTitle($0, for: column.id) }
            .onURLChange { model.setURL($0, for: column.id) }
            .onFinishLoad { model.didFinishLoad($0, title: $1, for: column.id); refresh() }
    }
}
