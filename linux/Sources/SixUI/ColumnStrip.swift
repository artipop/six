import Adwaita
import CAdw
import Foundation

/// The strip: `NiriLayout` computes rectangles, this puts widgets at them. That is the entire
/// relationship, and it is why the layout model crossed platforms untouched.
///
/// Written as a widget of its own because adwaita's stock `Fixed.element(x:y:id:)` cannot take a
/// child that was not there when the container was built — its appear functions run once, inside
/// `container`, and a column added later would silently never appear. Columns come and go
/// constantly, so the diffing is done here: keyed by tab id, kept across updates, and only the
/// difference is put in or taken out.
///
/// Keeping a column's storage across updates is not an optimisation. A rebuilt child is a rebuilt
/// `WebKitWebView`, which is a page thrown away and loaded again — so identity *is* the feature.
struct ColumnStrip: AdwaitaWidget {
    /// One per column: what to draw, where, and the identity that keeps its page alive.
    var columns: [(id: UUID, frame: CGRect, content: Body)]

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let fixed = gtk_fixed_new()
        // A `GtkFixed` asks for nothing — its children are placed, not packed — so without this it
        // is allocated 0×0 and the strip is invisible with no error anywhere.
        gtk_widget_set_hexpand(fixed, 1)
        gtk_widget_set_vexpand(fixed, 1)
        let storage = ViewStorage(fixed?.opaque())
        update(storage, data: data, updateProperties: true, type: type)
        return storage
    }

    func update<Data>(_ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type)
    where Data: ViewRenderData {
        let fixed = storage.opaquePointer
        var live: Set<String> = []

        for column in columns {
            let key = column.id.uuidString
            live.insert(key)

            let child: ViewStorage
            if let existing = storage.content[key]?.first {
                child = existing
                column.content.updateStorage(child, data: data, updateProperties: updateProperties, type: type)
            } else {
                child = column.content.storage(data: data, type: type)
                gtk_fixed_put(fixed?.cast(), child.opaquePointer?.cast(), column.frame.minX, column.frame.minY)
                storage.content[key] = [child]
            }

            gtk_widget_set_size_request(
                child.opaquePointer?.cast(),
                Int32(column.frame.width),
                Int32(column.frame.height)
            )
            gtk_fixed_move(fixed?.cast(), child.opaquePointer?.cast(), column.frame.minX, column.frame.minY)
        }

        // A column the model no longer has takes its page with it.
        for (key, children) in storage.content where !live.contains(key) {
            for child in children { gtk_fixed_remove(fixed?.cast(), child.opaquePointer?.cast()) }
            storage.content[key] = nil
        }
    }
}
