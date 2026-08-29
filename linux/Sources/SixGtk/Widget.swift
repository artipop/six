import CWebKitGTK
import Foundation

/// A GTK widget, with the reference counting and the signal bridge that `GObjectRef` already
/// carries. Everything the front puts on screen is one of these or a subclass of one.
///
/// This is deliberately thin. It is not a binding library and should not grow into one: the front
/// needs a window, a fixed canvas, a box, an entry, a label, a button and a web view, and anything
/// past that is added when something asks for it rather than in advance.
/// Which way a box lays its children out. Spelled here rather than passed through as GTK's own enum,
/// because the point of this module is that nothing above it imports C.
public enum Orientation {
    case horizontal
    case vertical

    var gtk: GtkOrientation { self == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL }
}

@MainActor
open class Widget: GObjectRef {
    public var widget: UnsafeMutablePointer<GtkWidget> {
        raw.assumingMemoryBound(to: GtkWidget.self)
    }

    public func setSizeRequest(width: Int, height: Int) {
        gtk_widget_set_size_request(widget, Int32(width), Int32(height))
    }

    public var isVisible: Bool {
        get { gtk_widget_get_visible(widget) != 0 }
        set { gtk_widget_set_visible(widget, newValue ? 1 : 0) }
    }

    /// Where this widget sits inside another, asked of the toolkit rather than remembered. Used for
    /// hit-testing checks and for anything that needs a child's real rectangle.
    public func bounds(in ancestor: Widget) -> CGRect? {
        var rect = graphene_rect_t()
        guard gtk_widget_compute_bounds(widget, ancestor.widget, &rect) != 0 else { return nil }
        return CGRect(x: CGFloat(rect.origin.x), y: CGFloat(rect.origin.y),
                      width: CGFloat(rect.size.width), height: CGFloat(rect.size.height))
    }

    /// Take the space going spare. The page does, the title bar above it does not.
    public func expand(horizontally: Bool = false, vertically: Bool = false) {
        if horizontally { gtk_widget_set_hexpand(widget, 1) }
        if vertically { gtk_widget_set_vexpand(widget, 1) }
    }

    public func addCSSClass(_ name: String) { gtk_widget_add_css_class(widget, name) }
    public func removeCSSClass(_ name: String) { gtk_widget_remove_css_class(widget, name) }
}

/// The strip's canvas. `NiriLayout` computes rectangles and this puts widgets at them — that is the
/// whole of the relationship, and the reason the layout model crossed platforms untouched.
@MainActor
public final class Fixed: Widget {
    private var children: [ObjectIdentifier: Widget] = [:]

    public init() { super.init(gtk_fixed_new()!) }

    public func put(_ child: Widget, at point: CGPoint) {
        gtk_fixed_put(cast(widget), child.widget, Double(point.x), Double(point.y))
        children[ObjectIdentifier(child)] = child
    }

    public func move(_ child: Widget, to point: CGPoint) {
        gtk_fixed_move(cast(widget), child.widget, Double(point.x), Double(point.y))
    }

    public func remove(_ child: Widget) {
        guard children.removeValue(forKey: ObjectIdentifier(child)) != nil else { return }
        gtk_fixed_remove(cast(widget), child.widget)
    }

    public var contents: [Widget] { Array(children.values) }
}

/// Not `final`: a column is a box with a title bar and a page in it, and saying so by inheritance is
/// the shortest true thing.
@MainActor
open class Box: Widget {
    public init(_ orientation: Orientation, spacing: Int = 0) {
        super.init(gtk_box_new(orientation.gtk, Int32(spacing))!)
    }

    public func append(_ child: Widget) { gtk_box_append(cast(widget), child.widget) }
    public func remove(_ child: Widget) { gtk_box_remove(cast(widget), child.widget) }
}

/// Note the `opaque(...)` here against `cast(...)` elsewhere: whether a GTK type reaches Swift as
/// `UnsafeMutablePointer<GtkX>` or as `OpaquePointer` depends on whether its struct is declared in
/// the public headers, and it varies type by type — `GtkFixed`, `GtkBox`, `GtkWindow` and `GtkEntry`
/// are structs, `GtkLabel` is not. The compiler says which; there is no rule to remember beyond that.
@MainActor
public final class Label: Widget {
    public init(_ text: String = "") { super.init(gtk_label_new(text)!) }

    public var text: String {
        get { gtk_label_get_text(opaque(widget)).map { String(cString: $0) } ?? "" }
        set { gtk_label_set_text(opaque(widget), newValue) }
    }

    /// A title that is longer than its column shortens in the middle, the way a title bar does.
    public func truncate(to characters: Int) {
        gtk_label_set_ellipsize(opaque(widget), PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_max_width_chars(opaque(widget), Int32(characters))
    }
}

@MainActor
public final class Button: Widget {
    public init(label: String) { super.init(gtk_button_new_with_label(label)!) }

    public func onClick(_ body: @escaping @MainActor () -> Void) { on("clicked", body) }
}

/// The address bar. `activate` is Enter, which is the only way six's ever submits.
@MainActor
public final class Entry: Widget {
    public init() { super.init(gtk_entry_new()!) }

    public var text: String {
        get {
            guard let buffer = gtk_entry_get_buffer(cast(widget)),
                  let text = gtk_entry_buffer_get_text(buffer) else { return "" }
            return String(cString: text)
        }
        set {
            guard let buffer = gtk_entry_get_buffer(cast(widget)) else { return }
            gtk_entry_buffer_set_text(buffer, newValue, -1)
        }
    }

    public func onSubmit(_ body: @escaping @MainActor () -> Void) { on("activate", body) }

    public func focus() { gtk_widget_grab_focus(widget) }
}

/// One window, always — the same constraint the Mac has, and for a related reason: a `WebKitWebView`
/// belongs to exactly one place in exactly one widget tree.
@MainActor
public final class Window: Widget {
    public init(application: Application, title: String) {
        super.init(gtk_application_window_new(cast(application.raw))!)
        gtk_window_set_title(cast(widget), title)
    }

    public func setDefaultSize(width: Int, height: Int) {
        gtk_window_set_default_size(cast(widget), Int32(width), Int32(height))
    }

    public func setChild(_ child: Widget) { gtk_window_set_child(cast(widget), child.widget) }

    public func present() { gtk_window_present(cast(widget)) }

    /// The viewport the strip lays itself out in. Asked for on every resize.
    public var contentSize: CGSize {
        CGSize(width: CGFloat(gtk_widget_get_width(widget)), height: CGFloat(gtk_widget_get_height(widget)))
    }
}

@MainActor
public final class Application: GObjectRef {
    public init(id: String) {
        super.init(UnsafeMutableRawPointer(gtk_application_new(id, G_APPLICATION_DEFAULT_FLAGS)!))
    }

    public func onActivate(_ body: @escaping @MainActor () -> Void) { on("activate", body) }

    public func run() -> Int32 { g_application_run(cast(raw), 0, nil) }

    public func quit() { g_application_quit(cast(raw)) }
}
