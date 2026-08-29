import Adwaita
import CAdw
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
    /// The strip's shape, assigned from actions and never during a render.
    ///
    /// A counter that nothing reads does not work: Meta re-renders a view when the state it *reads*
    /// changes, so bumping a write-only `revision` left the new tab and the typed address with no
    /// way to reach the screen. Holding the derived list is what makes the dependency real.
    ///
    /// Seeded from the model rather than left empty and filled from `onAppear`: a state assignment
    /// made while the view is first appearing does not reach the screen — the body has already been
    /// evaluated with the old value, and nothing re-renders. The model fills itself at construction,
    /// so the first read is already right.
    @State private var columns: [BrowserModel.Column] = BrowserModel.shared.columns
    @State private var typed = ""
    @State private var showsHistory = false

    private var model: BrowserModel { .shared }

    public init() {}

    public var view: Body {
        VStack {
            toolbar
            strip
                .vexpand()
            shortcuts
        }
        .dialog(visible: $showsHistory, title: "History", width: 640, height: 520) {
            HistorySheet(visible: $showsHistory)
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
            // `entryActivated`, not `onSubmit` — the latter exists on every view and quietly binds
            // to nothing here, which is why Enter in the address bar did nothing at all.
            EntryRow("Address", text: $typed)
                .entryActivated { model.go(to: typed); refresh() }
                .hexpand()
            Button(icon: .default(icon: .documentOpenRecent)) { showsHistory = true }
                .flat()
                .tooltip("History")
            Button(icon: .default(icon: .listAdd)) { model.openColumn(); refresh() }
                .flat()
        }
        .padding(6)
        .style("toolbar")
    }

    /// Pull the strip's shape out of the model. Safe from an action; never called during a render,
    /// which is what sent the view tree into a 248-render runaway the first time.
    func refresh() { columns = model.columns }

    /// Keyboard shortcuts.
    ///
    /// adwaita binds an accelerator to a *button's* action, so the shortcuts are a row of buttons
    /// that is never shown. That reads oddly and is exactly right: the action lives in one place,
    /// and the key and the toolbar press the same thing.
    ///
    /// Ctrl rather than ⌘, and `<Alt>` where the Mac uses ⌥ — the strip's own gestures keep their
    /// meaning, the platform's conventions keep theirs.
    @ViewBuilder var shortcuts: Body {
        HStack {
            Button("") { model.openColumn(); refresh() }.keyboardShortcut("<Ctrl>t")
            Button("") { model.closeColumn(); refresh() }.keyboardShortcut("<Ctrl>w")
            Button("") { model.reload() }.keyboardShortcut("<Ctrl>r")
            Button("") { showsHistory = true }.keyboardShortcut("<Ctrl>h")
            Button("") { model.focusColumn(-1); refresh() }.keyboardShortcut("<Alt>Left")
            Button("") { model.focusColumn(1); refresh() }.keyboardShortcut("<Alt>Right")
            Button("") { model.focusWorkspace(-1); refresh() }.keyboardShortcut("<Alt>Up")
            Button("") { model.focusWorkspace(1); refresh() }.keyboardShortcut("<Alt>Down")
            Button("") { model.cycleWidth(); refresh() }.keyboardShortcut("<Alt>r")
        }
        .visible(false)
    }

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
                ForEach(columns) { column in
                    columnView(column)
                }
            }
            .padding(Int(gap))
        }
        // The strip follows the focus. Without this a new column is created, laid out past the right
        // edge, and never seen — which is what "the plus button does nothing" actually was.
        //
        // `NiriLayout.resolvedOffset` is the same number the Mac scrolls to, centring the focused
        // column when `centersFocus` is on. Reaching the adjustment needs the widget, and `inspect`
        // is adwaita's documented way to get at one.
        .inspectOnAppear { storage in
            // ⌥ + scroll walks the strip, the way the Mac's `NiriScrollMonitor` does it. The
            // modifier is not decoration: over a page an unmodified gesture belongs to the page.
            guard let scrolled = storage.opaquePointer else { return }
            let controller = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)
            gtk_widget_add_controller(scrolled.cast(), controller)
            ScrollHandler.attach(controller) { dx, dy in
                guard ScrollHandler.altHeld(controller) else { return false }
                model.focusColumn(abs(dx) > abs(dy) ? (dx > 0 ? 1 : -1) : (dy > 0 ? 1 : -1))
                refresh()
                return true
            }
        }
        .inspect { storage, _ in
            guard let scrolled = storage.opaquePointer,
                  let adjustment = gtk_scrolled_window_get_hadjustment(scrolled) else { return }
            let target = model.scrollOffset
            if abs(gtk_adjustment_get_value(adjustment) - target) > 0.5 {
                gtk_adjustment_set_value(adjustment, target)
            }
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
        // Clicking a column focuses it, which is also what scrolls the strip to it — the offset
        // follows the focus, so the two are one gesture rather than two. In the capture phase,
        // because the page is on top and would otherwise swallow it.
        .inspectOnAppear { storage in
            ScrollHandler.onClickCapture(storage.opaquePointer?.cast()) {
                model.focus(column.id)
                refresh()
            }
        }
    }

    /// Built as a value first: the page's own modifiers belong to `WebView`, and a `Body` has none
    /// of them.
    func page(for column: BrowserModel.Column) -> WebView {
        WebView(url: column.url, tabID: column.id, session: model.session)
            .onTitleChange { if model.setTitle($0, for: column.id) { refresh() } }
            .onURLChange { if model.setURL($0, for: column.id) { refresh() } }
            .onFinishLoad { model.didFinishLoad($0, title: $1, for: column.id); refresh() }
    }
}
