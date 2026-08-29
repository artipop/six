import CWebKitGTK
import Foundation

// The half-day experiment the plan asks for before any of the Linux front is written. Two questions,
// and they are the two that would send us back to the drawing board:
//
//   1. Does a `WebKitWebView` survive being moved around a `GtkFixed`? The strip does nothing else —
//      `NiriLayout.columnFrames()` hands out rectangles and the front puts widgets at them — so if a
//      page reloads when its column slides, the whole layout model is the wrong shape here.
//
//   2. When something sits *on top of* a web view — six's permission bar is exactly this — does a
//      click land in the thing on top, and does a click beside it still reach the page underneath?
//      This is what swift-cross-ui's issue #729 gets wrong, and the reason we are not using it. The
//      claim is that the bug is theirs (a `Gtk.Fixed` wrapper per view, left targetable) rather than
//      GTK's. This is where that claim gets tested.
//
// Hit-testing is measured with `gtk_widget_pick()` rather than by clicking: it is the exact call
// `#729` reports on, it needs no input device, and it answers the same question deterministically
// under Xvfb.

// MARK: - The small amount of C glue any GTK-from-Swift program needs

/// GTK's `GTK_WIDGET()` / `GTK_WINDOW()` family are C macros, so they do not survive into Swift and
/// every downcast is written out. This is the tax the plan priced in, and it is most of it.
@inline(__always)
func cast<T>(_ pointer: UnsafeMutablePointer<some Any>?) -> UnsafeMutablePointer<T>? {
    UnsafeMutableRawPointer(pointer)?.assumingMemoryBound(to: T.self)
}

/// What a widget actually is, for reporting a `pick` result.
func typeName(of widget: UnsafeMutablePointer<some Any>?) -> String {
    guard let widget else { return "(nothing)" }
    let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
    guard let name = g_type_name_from_instance(instance) else { return "(untyped)" }
    return String(cString: name)
}

typealias SignalHandler = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

@discardableResult
func connect(_ object: UnsafeMutablePointer<some Any>, _ signal: String, _ handler: SignalHandler) -> CUnsignedLong {
    g_signal_connect_data(
        UnsafeMutableRawPointer(object),
        signal,
        unsafeBitCast(handler, to: GCallback.self),
        nil,
        nil,
        GConnectFlags(rawValue: 0)
    )
}

// MARK: - The scene

/// A column is a web view; the strip is a `GtkFixed`. Nothing here is a design — it is the smallest
/// arrangement that can answer the two questions.
enum Scene {
    nonisolated(unsafe) static var fixed: UnsafeMutablePointer<GtkWidget>?
    nonisolated(unsafe) static var columns: [UnsafeMutablePointer<GtkWidget>] = []
    /// The stand-in for `PermissionBar`: opaque, interactive, sitting over the first column.
    nonisolated(unsafe) static var bar: UnsafeMutablePointer<GtkWidget>?
    nonisolated(unsafe) static var barLabel: UnsafeMutablePointer<GtkWidget>?
    nonisolated(unsafe) static var barButton: UnsafeMutablePointer<GtkWidget>?
    nonisolated(unsafe) static var application: UnsafeMutablePointer<GtkApplication>?

    static let columnWidth = 500.0
    static let columnHeight = 700.0
    static let gap = 20.0
    /// Where the columns start, and where they are moved to, to prove a page outlives the move.
    static let firstX = 0.0
    static let movedX = 60.0

    static func page(_ title: String, _ colour: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="margin:0;background:\(colour);font:28px system-ui;color:#fff">
        <p style="padding:24px">\(title)</p></body></html>
        """
    }
}

func buildScene(application: UnsafeMutablePointer<GtkApplication>) {
    let window = gtk_application_window_new(application)
    gtk_window_set_default_size(cast(window), 1100, 760)

    let fixed = gtk_fixed_new()
    Scene.fixed = fixed
    gtk_window_set_child(cast(window), fixed)

    // Two columns, side by side, laid out from explicit coordinates the way `columnFrames()` gives
    // them. Loaded from a string rather than the network: the question is the widget, not the web.
    for (index, colour) in ["#2a4d8f", "#8f4d2a"].enumerated() {
        let view = webkit_web_view_new()!
        gtk_widget_set_size_request(view, Int32(Scene.columnWidth), Int32(Scene.columnHeight))
        let x = Scene.firstX + Double(index) * (Scene.columnWidth + Scene.gap)
        gtk_fixed_put(cast(fixed), view, x, 0)
        webkit_web_view_load_html(cast(view), Scene.page("column \(index + 1)", colour), nil)
        Scene.columns.append(view)
    }

    // The permission bar: added last, so it is on top, and overlapping column 1 the way six's does.
    let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
    gtk_widget_set_size_request(bar, 320, 44)
    let label = gtk_label_new("Allow camera?")!
    let allow = gtk_button_new_with_label("Allow")!
    gtk_box_append(cast(bar), label)
    gtk_box_append(cast(bar), allow)
    gtk_fixed_put(cast(fixed), bar, 24, 24)
    Scene.bar = bar
    Scene.barLabel = label
    Scene.barButton = allow

    gtk_window_present(cast(window))
}

// MARK: - The measurements

/// Ask GTK what is under a point, the way a click would.
func pick(_ x: Double, _ y: Double) -> UnsafeMutablePointer<GtkWidget>? {
    guard let fixed = Scene.fixed else { return nil }
    return gtk_widget_pick(fixed, x, y, GTK_PICK_DEFAULT)
}

/// `pick` returns the *deepest* widget under the point, which is the right answer and not usually the
/// one you named: the centre of a `gtk_button_new_with_label` is that button's own `GtkLabel`, and the
/// centre of a web view is whatever WebKit puts inside itself. So the question worth asking is not
/// "which class" but "whose", and that is what a click cares about too — the bar's subtree or the
/// page's.
func isWithin(_ widget: UnsafeMutablePointer<GtkWidget>?, _ ancestor: UnsafeMutablePointer<GtkWidget>?) -> Bool {
    guard let widget, let ancestor else { return false }
    if widget == ancestor { return true }
    return gtk_widget_is_ancestor(widget, ancestor) != 0
}

/// Where a widget actually ended up, in the strip's coordinates. Probing a coordinate the author
/// invented measures the author; this asks the toolkit.
func centre(of widget: UnsafeMutablePointer<GtkWidget>?) -> (x: Double, y: Double)? {
    guard let widget, let fixed = Scene.fixed else { return nil }
    var bounds = graphene_rect_t()
    guard gtk_widget_compute_bounds(widget, fixed, &bounds) != 0 else { return nil }
    return (Double(bounds.origin.x + bounds.size.width / 2),
            Double(bounds.origin.y + bounds.size.height / 2))
}

func report() {
    print("")
    print("=== 1. does a page survive being moved? ===")
    // Slide both columns along the strip, exactly as a scroll would.
    for (index, view) in Scene.columns.enumerated() {
        let x = Scene.movedX + Double(index) * (Scene.columnWidth + Scene.gap)
        gtk_fixed_move(cast(Scene.fixed), view, x, 0)
    }
    // Let the move settle through one layout pass.
    while g_main_context_pending(nil) != 0 { g_main_context_iteration(nil, 0) }

    for (index, view) in Scene.columns.enumerated() {
        let title = webkit_web_view_get_title(cast(view)).map { String(cString: $0) } ?? "(none)"
        let loading = webkit_web_view_is_loading(cast(view)) != 0
        let expected = "column \(index + 1)"
        let verdict = (title == expected && !loading) ? "СТРАНИЦА ЖИВА" : "ПОТЕРЯНА"
        print("  column \(index + 1): title=\(title.isEmpty ? "(empty)" : title) loading=\(loading) -> \(verdict)")
    }

    print("")
    print("=== 2. hit-testing with a bar on top of a page (the #729 question) ===")
    // Coordinates are in the strip's space, and the columns have just moved to `movedX`.
    // Every probe is aimed at a widget's measured centre, or at a point defined relative to one.
    struct Probe {
        let what: String
        let x: Double
        let y: Double
        let owner: UnsafeMutablePointer<GtkWidget>?
        let ownerName: String
        let note: String
    }
    var probes: [Probe] = []

    if let p = centre(of: Scene.barLabel) {
        probes.append(Probe(what: "the bar's label", x: p.x, y: p.y, owner: Scene.bar, ownerName: "the bar",
                            note: "a control in the bar answers for itself"))
    }
    if let p = centre(of: Scene.barButton) {
        probes.append(Probe(what: "the bar's button", x: p.x, y: p.y, owner: Scene.bar, ownerName: "the bar",
                            note: "the one the user actually clicks"))
    }
    if let bar = centre(of: Scene.bar), let button = centre(of: Scene.barButton) {
        // Padding inside the bar, past the last control. This must NOT reach the page: a bar that
        // leaks clicks through its own empty half is worse than no bar.
        probes.append(Probe(what: "the bar's empty right end", x: button.x + 60, y: bar.y, owner: Scene.bar, ownerName: "the bar",
                            note: "the bar absorbs its whole width"))
    }
    if let first = Scene.columns.first, let p = centre(of: first) {
        probes.append(Probe(what: "page under the bar", x: p.x, y: 200, owner: first, ownerName: "column 1",
                            note: "just below the bar, the page is reachable"))
        probes.append(Probe(what: "page, far from the bar", x: p.x, y: p.y, owner: first, ownerName: "column 1",
                            note: "and so is the rest of it"))
    }
    if Scene.columns.count > 1, let p = centre(of: Scene.columns[1]) {
        probes.append(Probe(what: "the second column", x: p.x, y: p.y, owner: Scene.columns[1], ownerName: "column 2",
                            note: "a neighbour in the strip is its own target"))
    }

    var passed = 0
    for probe in probes {
        let picked = pick(probe.x, probe.y)
        let ok = isWithin(picked, probe.owner)
        if ok { passed += 1 }
        let name = probe.what.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("  \(ok ? "✓" : "✗") \(name) (\(Int(probe.x)),\(Int(probe.y))) -> \(typeName(of: picked)) in \(probe.ownerName)")
        print("      \(probe.note)")
    }
    print("")
    print("  \(passed)/\(probes.count) точек попали туда, куда должен попасть клик")
    if passed == probes.count {
        print("  ВЫВОД: GtkFixed не съедает клики — бар не течёт, страница под ним доступна,")
        print("  соседняя колонка сама себе цель. Значит #729 у swift-cross-ui свой (обёртка")
        print("  на каждый вид), а не гтк-шный, и костыли HostedOverlay/ClickCatcher не нужны.")
    } else {
        print("  ВЫВОД: точка потеряна — смотреть, что именно вернулось выше.")
    }

    if let application = Scene.application {
        g_application_quit(cast(application))
    }
}

// MARK: - Run

let app = gtk_application_new("dev.six.gtkspike", G_APPLICATION_DEFAULT_FLAGS)!
Scene.application = app

connect(app, "activate") { application, _ in
    guard let application else { return }
    buildScene(application: application.assumingMemoryBound(to: GtkApplication.self))
    // Give WebKit a moment to have its processes up and the pages laid out, then measure.
    g_timeout_add_seconds(2, { _ in
        report()
        return 0  // G_SOURCE_REMOVE
    }, nil)
}

let status = g_application_run(cast(app), 0, nil)
exit(status)
