import Adwaita
import CAdw
import Foundation
import SixBrowser
import SixWebKit

/// The browser, declaratively. One window, always — what look like tabs are columns in the strip
/// inside it, which is the whole niri idea and the same constraint the Mac has.
public struct BrowserContent: View {
    /// The strip's shape, reassigned from actions and never during a render.
    ///
    /// Only value types live in `@State`: Meta reflects over a view's stored properties to find it,
    /// and a class in there takes the runtime down inside `swift_getTypeByMangledName`. The model is
    /// `BrowserModel.shared` instead, and this holds what it says the strip looks like.
    ///
    /// Holding the derived list, rather than a counter, is what makes the dependency real: Meta
    /// re-renders a view when the state it *reads* changes, so bumping a write-only `revision` left
    /// the new column and the typed address with no way to reach the screen.
    ///
    /// Seeded from the model rather than left empty and filled from `onAppear`: a state assignment
    /// made while the view is first appearing does not reach the screen — the body has already been
    /// evaluated with the old value, and nothing re-renders. The model fills itself at construction,
    /// so the first read is already right.
    @State private var columns: [BrowserModel.Column] = BrowserModel.shared.columns
    @State private var typed = ""
    @State private var showsHistory = false
    @State private var showsBookmarks = false
    @State private var showsPermissions = false

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
        .dialog(visible: $showsBookmarks, title: "Bookmarks", width: 640, height: 520) {
            BookmarksSheet(visible: $showsBookmarks)
        }
        .dialog(visible: $showsPermissions, title: "Site Permissions", width: 640, height: 520) {
            PermissionsSheet(visible: $showsPermissions)
        }
        // A question arrives from a C signal, and a signal assigns no view state. This is the one
        // place the model is allowed to reach back into the front, and it does the same thing every
        // action here does: pull the strip's shape out again.
        .inspectOnAppear { _ in
            model.onPermissionQuestion = { refresh() }
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
            Button(icon: .default(icon: model.isPrivate ? .viewReveal : .viewConceal)) {
                if model.isPrivate { model.closePrivateProfile() } else { model.openPrivateProfile() }
                refresh()
            }
            .flat()
            .tooltip(model.isPrivate ? "Leave private browsing" : "Private window")
            Button(icon: .default(icon: .viewFullscreen)) { model.toggleOverview(); refresh() }
                .flat()
                .tooltip("Overview")
            Button(icon: .default(icon: model.isBookmarked ? .starred : .nonStarred)) {
                model.toggleBookmark(); refresh()
            }
            .flat()
            .tooltip(model.isBookmarked ? "Remove bookmark" : "Bookmark this page")
            Button(icon: .default(icon: .userBookmarks)) { showsBookmarks = true }
                .flat()
                .tooltip("Bookmarks")
            Button(icon: .default(icon: .documentOpenRecent)) { showsHistory = true }
                .flat()
                .tooltip("History")
            Button(icon: .default(icon: .cameraWeb)) { showsPermissions = true }
                .flat()
                .tooltip("Site permissions")
            Button(icon: .default(icon: .listAdd)) { model.openColumn(); refresh() }
                .flat()
        }
        .padding(6)
        .style(model.isPrivate ? "toolbar suggested-action" : "toolbar")
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
            Button("") { model.toggleOverview(); refresh() }.keyboardShortcut("<Alt>o")
            Button("") { model.toggleBookmark(); refresh() }.keyboardShortcut("<Ctrl>d")
            Button("") { showsBookmarks = true }.keyboardShortcut("<Ctrl>b")
            Button("") {
                if model.isPrivate { model.closePrivateProfile() } else { model.openPrivateProfile() }
                refresh()
            }
            .keyboardShortcut("<Ctrl><Shift>p")
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
            // The overview scales the whole canvas rather than re-laying it out, which is what makes
            // it a way of looking at the strip rather than a second layout. `GtkFixed` is the only
            // container that can transform a child, and one static child is exactly what adwaita's
            // own `element(x:y:id:)` handles — managing its storage by hand is what crashed this
            // once already.
            Fixed()
                .element(x: 0, y: 0, id: "canvas") {
                    HStack(spacing: Int(gap)) {
                        ForEach(columns) { column in
                            columnView(column)
                        }
                    }
                    .padding(Int(gap))
                }
                .inspect { storage, _ in
                    guard let fixed = storage.opaquePointer,
                          let canvas = storage.content["canvas"]?.first?.opaquePointer else { return }
                    let scale = Float(model.overviewScale)
                    // A scale is anchored at the top left, so on its own it leaves the strip pinned
                    // to the top of the window with a band of nothing underneath. One translation
                    // before it puts the shrunk strip back in the middle, which is where an overview
                    // of it belongs.
                    let height = Float(gtk_widget_get_height(canvas.cast()))
                    var origin = graphene_point_t(x: 0, y: (height - height * scale) / 2)
                    let transform = gsk_transform_scale(
                        gsk_transform_translate(nil, &origin), scale, scale)
                    gtk_fixed_set_child_transform(fixed.cast(), canvas.cast(), transform)
                    gtk_widget_set_size_request(
                        fixed.cast(),
                        Int32(model.contentWidth * model.overviewScale),
                        -1
                    )
                }
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
            guard let scrolled = storage.opaquePointer else { return }
            // How big the strip actually is. `NiriLayout` needs the viewport to size a column and to
            // decide where the focused one sits, and this widget's allocation *is* the viewport —
            // the window minus the toolbar. Reported from here because GTK has no `GeometryReader`
            // and a widget's allocation is not a property one can watch.
            //
            // Safe to do during a render only because it settles: `updateViewport` returns false for
            // a size it already has, so the redraw happens on the render after a resize and not on
            // every one. Asking for a render unconditionally from here is what produced the
            // 248-render runaway.
            let size = CGSize(
                width: Double(gtk_widget_get_width(scrolled.cast())),
                height: Double(gtk_widget_get_height(scrolled.cast()))
            )
            if model.updateViewport(size) { refresh() }

            guard let adjustment = gtk_scrolled_window_get_hadjustment(scrolled) else { return }
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
            if let question = column.permission {
                permissionBar(question, in: column.id)
            }
            // A discarded column keeps its place and its address, and builds a page again when the
            // strip brings it back — the same thing the Mac does, and for the same reason: a strip
            // of a hundred columns cannot hold a hundred web content processes.
            if column.isLive {
                page(for: column).vexpand()
            } else {
                // The picture the page left behind, if it left one. Otherwise its name and address,
                // which is still more than a blank card.
                if let thumbnail = column.thumbnail {
                    Picture(url: thumbnail)
                        .contentFit(.cover)
                        .vexpand()
                } else {
                    StatusPage(
                        column.title.isEmpty ? "Discarded" : column.title,
                        icon: .default(icon: .viewRefresh),
                        description: column.url?.absoluteString ?? ""
                    )
                    .vexpand()
                }
            }
        }
        // The size belongs to the *column*, not to the page inside it. Asking the page for
        // `columnHeight` and then stacking a title bar and a permission bar on top of it made the
        // card taller than the strip, so every column ran off the bottom edge of the window.
        // `columnHeight` is already the viewport minus its gaps, which is what a column is.
        .frame(
            minWidth: Int(model.columnSize.width),
            minHeight: Int(model.columnSize.height)
        )
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

    /// What a site is asking for, drawn where the answer belongs: in the column that asked, under
    /// its own title.
    ///
    /// A bar rather than a dialog, and that is the same judgement the Mac makes in `PermissionBar`:
    /// a dialog belongs to the app, and one column of twenty wanting the camera is no reason to stop
    /// the other nineteen. It pushes the page down instead of covering it, so its buttons are
    /// siblings of the web view rather than something drawn over it — which is also how they keep
    /// the mouse.
    ///
    /// The page is suspended inside `getUserMedia()` for exactly as long as this is up.
    @ViewBuilder func permissionBar(
        _ question: BrowserModel.PermissionQuestion,
        in tabID: UUID
    ) -> Body {
        HStack {
            Symbol(icon: .default(icon: question.wantsCamera ? .cameraWeb : .audioInputMicrophone))
                .padding(4)
            Text("\(question.host) wants to use your \(question.devices).")
                .ellipsize()
                .hexpand()
            Button("Block") { model.answerPermission(false, for: tabID); refresh() }
            Button("Allow") { model.answerPermission(true, for: tabID); refresh() }
                .style("suggested-action")
        }
        .padding(6)
        .style("toolbar")
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
