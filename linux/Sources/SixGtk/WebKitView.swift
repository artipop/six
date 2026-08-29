import CWebKitGTK
import Foundation

/// A profile's cookies, caches and storage. `WebKitNetworkSession` is the direct counterpart of
/// `WKWebsiteDataStore(forIdentifier:)`: one per profile, and an ephemeral one for a private profile,
/// which is the same arrangement six already has on the Mac.
@MainActor
public final class NetworkSession: GObjectRef {
    /// A profile that keeps what it collects, under its own directory.
    public init(directory: URL) {
        let data = directory.appending(path: "data", directoryHint: .isDirectory).path
        let cache = directory.appending(path: "cache", directoryHint: .isDirectory).path
        super.init(UnsafeMutableRawPointer(webkit_network_session_new(data, cache)!))
    }

    /// Private browsing: recorded nowhere, gone when the profile is dropped.
    public init() {
        super.init(UnsafeMutableRawPointer(webkit_network_session_new_ephemeral()!))
    }

    public var isEphemeral: Bool { webkit_network_session_is_ephemeral(opaque(raw)) != 0 }
}

/// A page. The Linux counterpart of `WebPage`, and — unlike it — a widget six owns outright, which
/// is what will let extensions work here that cannot work on the Mac (see docs/extensions.md).
@MainActor
public final class WebView: Widget {
    public private(set) var session: NetworkSession

    /// `webkit_web_view_new()` takes nothing, and the session is a *construct-only* property, so the
    /// view has to be built with the property already set. `g_object_new` is variadic and out of
    /// Swift's reach; `g_object_new_with_properties` takes arrays and is not.
    public init(session: NetworkSession) {
        self.session = session
        var value = GValue()
        g_value_init(&value, webkit_network_session_get_type())
        g_value_set_object(&value, session.raw)
        let view: UnsafeMutablePointer<GtkWidget> = "network-session".withCString { name in
            var names: [UnsafePointer<CChar>?] = [name]
            let object = g_object_new_with_properties(webkit_web_view_get_type(), 1, &names, &value)!
            return UnsafeMutableRawPointer(object).assumingMemoryBound(to: GtkWidget.self)
        }
        g_value_unset(&value)
        super.init(view)
    }

    // MARK: What the strip asks for without waking anything

    public var url: URL? {
        webkit_web_view_get_uri(cast(raw)).flatMap { URL(string: String(cString: $0)) }
    }

    public var title: String {
        webkit_web_view_get_title(cast(raw)).map { String(cString: $0) } ?? ""
    }

    public var isLoading: Bool { webkit_web_view_is_loading(cast(raw)) != 0 }

    public var estimatedProgress: Double { webkit_web_view_get_estimated_load_progress(cast(raw)) }

    public var canGoBack: Bool { webkit_web_view_can_go_back(cast(raw)) != 0 }
    public var canGoForward: Bool { webkit_web_view_can_go_forward(cast(raw)) != 0 }

    // MARK: Driving it

    public func load(_ url: URL) { webkit_web_view_load_uri(cast(raw), url.absoluteString) }
    public func load(html: String, baseURL: URL? = nil) {
        webkit_web_view_load_html(cast(raw), html, baseURL?.absoluteString)
    }
    public func reload() { webkit_web_view_reload(cast(raw)) }
    public func stop() { webkit_web_view_stop_loading(cast(raw)) }
    public func goBack() { webkit_web_view_go_back(cast(raw)) }
    public func goForward() { webkit_web_view_go_forward(cast(raw)) }

    // MARK: Watching it

    /// Every load event: started, redirected, committed, finished. History is written on `.finished`,
    /// the way the Mac writes it from the navigation stream.
    public func onLoadChanged(_ body: @escaping @MainActor (WebKitLoadEvent) -> Void) {
        onEvent("load-changed") { raw in body(WebKitLoadEvent(rawValue: raw)) }
    }

    /// The title arriving after the page has already committed — which is the usual order, so a title
    /// bar that only read on `.finished` would show the address for most of a page's life.
    public func onTitleChanged(_ body: @escaping @MainActor () -> Void) { onNotify("title", body) }

    public func onURLChanged(_ body: @escaping @MainActor () -> Void) { onNotify("uri", body) }
}
