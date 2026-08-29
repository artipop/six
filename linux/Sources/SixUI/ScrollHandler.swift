import Adwaita
import CAdw
import Foundation
import SixWebKitCore

/// The two GTK controllers the strip needs and adwaita has no wrapper for: ⌥ + scroll to walk the
/// columns, and a click seen before the page under it.
///
/// The boxing and the `g_signal_connect_data` are `Signal`'s; what is written out here is the
/// trampoline for each signal, because every one has a different C signature and a `@convention(c)`
/// function cannot be generic.
enum ScrollHandler {
    /// A click on a column, seen *before* the page under it gets the event.
    ///
    /// A web view is on top and consumes what lands on it, so a handler on the column would never
    /// fire — the same problem the Mac solves with an AppKit `ClickCatcher` that sets
    /// `acceptsFirstMouse`. GTK has a proper answer: a controller in the capture phase sees the
    /// event on the way down, before the child. The page still gets it afterwards, so clicking a
    /// link both focuses the column and follows the link, which is what a browser should do.
    static func onClickCapture(_ widget: UnsafeMutablePointer<GtkWidget>?, _ body: @escaping () -> Void) {
        let gesture = gtk_gesture_click_new()
        gtk_event_controller_set_propagation_phase(gesture, GTK_PHASE_CAPTURE)
        gtk_widget_add_controller(widget, gesture)
        // `void (*, gint n_press, gdouble x, gdouble y, gpointer)`
        let handler: @convention(c) (
            UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _, _, data in
            Signal.Box.open(data, as: (() -> Void).self)?()
        }
        Signal.connect(
            gesture.map { UnsafeMutableRawPointer($0) },
            to: "pressed",
            unsafeBitCast(handler, to: GCallback.self),
            holding: Signal.Box(body)
        )
    }

    /// Whether ⌥ is down for the event being delivered. Over a page an unmodified scroll is the
    /// page's, and taking it would make every strip a broken web page.
    static func altHeld(_ controller: OpaquePointer?) -> Bool {
        guard let event = gtk_event_controller_get_current_event(controller) else { return false }
        return gdk_event_get_modifier_state(event).rawValue & GDK_ALT_MASK.rawValue != 0
    }

    /// Scrolling. The closure returns whether the gesture was taken; returning false leaves it to
    /// the page, which is what an unmodified scroll must always be.
    static func attach(
        _ controller: OpaquePointer?,
        _ body: @escaping (Double, Double) -> Bool
    ) {
        // `gboolean (*, gdouble dx, gdouble dy, gpointer)` — a shape `SignalData.HandlerType` has no
        // case for, which is why this one is not pushed through adwaita's `connectSignal`.
        let handler: @convention(c) (
            UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?
        ) -> Int32 = { _, dx, dy, data in
            guard let body = Signal.Box.open(data, as: ((Double, Double) -> Bool).self) else { return 0 }
            return body(dx, dy) ? 1 : 0
        }
        Signal.connect(
            controller.map { UnsafeMutableRawPointer($0) },
            to: "scroll",
            unsafeBitCast(handler, to: GCallback.self),
            holding: Signal.Box(body)
        )
    }
}
