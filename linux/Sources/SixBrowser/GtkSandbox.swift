import CWebKitGTK
import Foundation
import SixWebKitCore

@testable internal import SixCore

/// The page six runs its own programs in, on this front: a `WebKitWebView` that belongs to no
/// window and is never drawn.
///
/// A `WebKitWebView` with no parent still has a web process, still loads, and still runs scripts —
/// what it does not have is a surface, which is exactly what is not wanted. That is what makes this
/// eleven lines where the Windows front needs a hidden `HWND` to host its view in.
///
/// Two things are set on it that no browsing page gets, and both are about the same fact: the page
/// is a `file:` document that has to `fetch()` a five megabyte wasm module and thirty megabytes of
/// weights out of the folder it lives in, which the same-origin rules forbid a `file:` document by
/// default. Nothing but six's own payload is ever loaded here, so the relaxation reaches nothing a
/// site could use.
final class GtkSandbox: PageSandbox {
    private var view: UnsafeMutablePointer<WebKitWebView>?
    private var page: LivePage?
    /// Whoever is waiting for `open` to finish. One at a time: `open` is called once per launch.
    private var loading: CheckedContinuation<Void, any Error>?

    func open(_ url: URL) async throws {
        let view = try ensureView()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loading = continuation
            webkit_web_view_load_uri(view, url.absoluteString)
        }
    }

    func call(_ body: String, input: String) async throws -> String {
        guard let page else { throw PageScriptError.noPage }
        return try await page.callAsync(body, input: input)
    }

    /// Called from the `load-changed` trampoline below, on the main loop.
    func finishedLoading() {
        guard let waiting = loading else { return }
        loading = nil
        waiting.resume()
    }

    private func ensureView() throws -> UnsafeMutablePointer<WebKitWebView> {
        if let view { return view }
        guard let widget = webkit_web_view_new() else { throw PageScriptError.noPage }
        // A fresh `GtkWidget` carries a floating reference, which the container it is added to would
        // normally sink. Nothing is going to add this one, so it sinks its own — without this the
        // view is destroyed the first time anything else unrefs it.
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        let created = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: WebKitWebView.self)

        if let settings = webkit_web_view_get_settings(created) {
            webkit_settings_set_allow_file_access_from_file_urls(settings, 1)
            webkit_settings_set_allow_universal_access_from_file_urls(settings, 1)
        }
        Signal.connect(
            UnsafeMutableRawPointer(created),
            to: "load-changed",
            unsafeBitCast(sandboxLoadChanged, to: GCallback.self),
            holding: Signal.Box(self)
        )

        view = created
        page = LivePage(created)
        return created
    }
}

/// `void (*)(WebKitWebView *, WebKitLoadEvent, gpointer)` — written out, because a handler entered
/// through the wrong C signature reads its user data from the wrong place and the crash lands
/// somewhere else entirely. `WebView.connect` has the account of the one time that happened here.
///
/// GTK emits its signals from the main loop and nowhere else, so the isolation assumed below is a
/// fact about GTK rather than a hope — the same sentence `PermissionRequests` ends on.
private let sandboxLoadChanged: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, event, data in
    guard event == WEBKIT_LOAD_FINISHED.rawValue, let data else { return }
    nonisolated(unsafe) let box = data
    MainActor.assumeIsolated {
        Signal.Box.open(box, as: GtkSandbox.self)?.finishedLoading()
    }
}
