import Adwaita
import CAdw
import Foundation

/// ⌥ + scroll, as a `GtkEventControllerScroll`.
///
/// adwaita has no wrapper for this controller, so the C API is used directly — one of the few places
/// the front still has to. The signal is `scroll (controller, dx, dy) -> gboolean`, which is not a
/// shape `SignalData.HandlerType` covers, so the trampoline is written out here rather than pushed
/// through `connectSignal`.
enum ScrollHandler {
    /// A click on a column, seen *before* the page under it gets the event.
    ///
    /// A web view is on top and consumes what lands on it, so a handler on the column would never
    /// fire — which is the same problem the Mac solves with an AppKit `ClickCatcher` that sets
    /// `acceptsFirstMouse`. GTK has a proper answer: a controller in the capture phase sees the
    /// event on the way down, before the child. The page still gets it afterwards, so clicking a
    /// link both focuses the column and follows the link, which is what a browser should do.
    static func onClickCapture(_ widget: UnsafeMutablePointer<GtkWidget>?, _ body: @escaping () -> Void) {
        let gesture = gtk_gesture_click_new()
        gtk_event_controller_set_propagation_phase(gesture, GTK_PHASE_CAPTURE)
        gtk_widget_add_controller(widget, gesture)
        let box = Unmanaged.passRetained(ClickBox(body)).toOpaque()
        let handler: @convention(c) (
            UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _, _, data in
            guard let data else { return }
            Unmanaged<ClickBox>.fromOpaque(data).takeUnretainedValue().body()
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<ClickBox>.fromOpaque(data).release()
        }
        g_signal_connect_data(
            gesture.map { UnsafeMutableRawPointer($0) },
            "pressed",
            unsafeBitCast(handler, to: GCallback.self),
            box,
            release,
            GConnectFlags(rawValue: 0)
        )
    }

    private final class ClickBox {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }

    private final class Box {
        let body: (Double, Double) -> Bool
        init(_ body: @escaping (Double, Double) -> Bool) { self.body = body }
    }

    /// Whether ⌥ is down for the event being delivered. Over a page an unmodified scroll is the
    /// page's, and taking it would make every strip a broken web page.
    static func altHeld(_ controller: OpaquePointer?) -> Bool {
        guard let event = gtk_event_controller_get_current_event(controller) else { return false }
        return gdk_event_get_modifier_state(event).rawValue & GDK_ALT_MASK.rawValue != 0
    }

    static func attach(
        _ controller: OpaquePointer?,
        _ body: @escaping (Double, Double) -> Bool
    ) {
        let box = Unmanaged.passRetained(Box(body)).toOpaque()
        let handler: @convention(c) (
            UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?
        ) -> Int32 = { _, dx, dy, data in
            guard let data else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
            return box.body(dx, dy) ? 1 : 0
        }
        let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).release()
        }
        g_signal_connect_data(
            controller.map { UnsafeMutableRawPointer($0) },
            "scroll",
            unsafeBitCast(handler, to: GCallback.self),
            box,
            release,
            GConnectFlags(rawValue: 0)
        )
    }
}
