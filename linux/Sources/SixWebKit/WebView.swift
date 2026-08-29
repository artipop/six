import Adwaita
import CWebKitGTK
import Foundation
import SixWebKitCore

/// A page, as a widget adwaita-swift can place.
///
/// This is the part of the Linux front that is ours whichever UI library wins: no Swift GTK binding
/// covers WebKitGTK, so the interop is written once and wrapped to suit whatever is drawing. The
/// shape follows `aparoksha/codeeditor`, which is the same trick for GtkSourceView and the reason we
/// know a foreign widget sits happily beside adwaita's own.
///
/// It is also the thing six *owns* here, unlike on the Mac where `WebPage` keeps its `WKWebView` to
/// itself — which is what will let extensions work on Linux that cannot work there
/// ([extensions.md](../../../docs/extensions.md)).
public struct WebView: AdwaitaWidget {
    /// Where the page should be. Assigning a different address navigates; assigning the same one
    /// does nothing, so an update that changes something else does not reload the page.
    var url: URL?
    /// The profile's cookies and caches. Construct-only, so it is read once and never updated.
    var session: NetworkSession
    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((URL) -> Void)?
    var onFinishLoad: ((URL, String) -> Void)?

    public init(url: URL?, session: NetworkSession) {
        self.url = url
        self.session = session
    }

    public func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage
    where Data: ViewRenderData {
        // `webkit_web_view_new()` takes nothing and the session is construct-only, so the view is
        // built with the property already set. `g_object_new` is variadic and out of Swift's reach;
        // `g_object_new_with_properties` takes arrays and is not.
        var value = GValue()
        g_value_init(&value, webkit_network_session_get_type())
        g_value_set_object(&value, session.pointer)
        let view = "network-session".withCString { name -> UnsafeMutableRawPointer? in
            var names: [UnsafePointer<CChar>?] = [name]
            return g_object_new_with_properties(webkit_web_view_get_type(), 1, &names, &value).map(UnsafeMutableRawPointer.init)
        }
        g_value_unset(&value)

        let storage = ViewStorage(view.map { OpaquePointer($0) })
        connect(storage)
        update(storage, data: data, updateProperties: true, type: type)
        return storage
    }

    public func update<Data>(_ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type)
    where Data: ViewRenderData {
        guard let view = storage.opaquePointer else { return }

        guard updateProperties, let url else { return }
        // Only navigate when the address actually differs. Every other update — a title arriving, a
        // neighbour column moving — must leave the page where it is.
        let current = webkit_web_view_get_uri(.init(view)).map { String(cString: $0) }
        if current != url.absoluteString, (storage.previousState as? Self)?.url != url {
            webkit_web_view_load_uri(.init(view), url.absoluteString)
        }
        storage.previousState = self
    }
}

extension WebView {
    /// Signals are connected **once**, when the widget is made — never in `update`.
    ///
    /// Connecting them there instead is what took the whole app down, and the way it failed is worth
    /// remembering: every re-render added another handler, each handler asked the view to refresh,
    /// and the refresh re-rendered. The crash surfaced as a bad pointer dereference inside adwaita's
    /// own `Button.update`, which is not where the mistake was — it was a stack overflow from
    /// `SafeWrapper.update` recursing into itself, and the button was simply what the runaway
    /// happened to be walking when the stack ran out.
    func connect(_ storage: ViewStorage) {
        guard let view = storage.opaquePointer else { return }
        storage.notify(name: "title") {
            let title = webkit_web_view_get_title(.init(view)).map { String(cString: $0) } ?? ""
            onTitleChange?(title)
        }
        storage.notify(name: "uri") {
            guard let uri = webkit_web_view_get_uri(.init(view)).map({ String(cString: $0) }),
                  let url = URL(string: uri) else { return }
            onURLChange?(url)
        }
        storage.connectSignal(name: "load-changed") {
            guard webkit_web_view_is_loading(.init(view)) == 0,
                  let uri = webkit_web_view_get_uri(.init(view)).map({ String(cString: $0) }),
                  let url = URL(string: uri) else { return }
            let title = webkit_web_view_get_title(.init(view)).map { String(cString: $0) } ?? ""
            onFinishLoad?(url, title)
        }
    }

    public func onTitleChange(_ body: @escaping (String) -> Void) -> Self {
        var copy = self
        copy.onTitleChange = body
        return copy
    }

    public func onURLChange(_ body: @escaping (URL) -> Void) -> Self {
        var copy = self
        copy.onURLChange = body
        return copy
    }

    public func onFinishLoad(_ body: @escaping (URL, String) -> Void) -> Self {
        var copy = self
        copy.onFinishLoad = body
        return copy
    }
}
