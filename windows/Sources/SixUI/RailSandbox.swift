import CWebKit2
import Foundation
@testable import SixCore
import WinSDK

/// The off-screen page six runs its own programs in — Bergamot today, an embedder next.
///
/// A real `WKView` in a real window that is never shown. It has to be a real one: WebKit's Windows
/// port draws into an `HWND` and a view without one is not a view, and a page without a view does
/// not run scripts. So there is a one-pixel `WS_POPUP` nobody sees, `ShowWindow` is never called on
/// it, and the page inside gets its own web process the way every other page does.
///
/// Two things are set on it that no browsing page gets. It reads its own files: a five megabyte
/// wasm module and thirty megabytes of weights, fetched with `fetch()` from beside the page, which
/// a `file:` document may not do unless it is told it may. And it browses in a non-persistent data
/// store, so nothing it does can land in a profile's cookie jar — it is not browsing, and the pages
/// it loads are six's own.
@MainActor
final class RailSandbox: PageSandbox {
    private static let className = "SixSandboxHost"

    private var host: HWND?
    private var webView: RailWebView?
    /// Whoever is waiting for `open` to finish. One at a time: `open` is called once per launch.
    private var loading: CheckedContinuation<Void, any Error>?

    func open(_ url: URL) async throws {
        let view = try ensureView()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loading = continuation
            view.onFinishNavigation = { [weak self] in
                guard let self, let waiting = loading else { return }
                loading = nil
                waiting.resume()
            }
            view.load(url.absoluteString)
        }
    }

    func call(_ body: String, input: String) async throws -> String {
        guard let webView else { throw RailScriptError.noPage }
        return try await webView.callAsync(body, input: input)
    }

    // MARK: The window nobody sees

    private func ensureView() throws -> RailWebView {
        if let webView { return webView }
        let instance = GetModuleHandleW(nil)
        registerClass(instance)

        let created = Self.className.withCString(encodedAs: UTF16.self) { name in
            "six sandbox".withCString(encodedAs: UTF16.self) { title in
                // Off the screen as well as unshown: a window at 0,0 that some other code decides to
                // show would be a one-pixel artefact in the corner of the display, and nobody would
                // ever work out where it came from.
                CreateWindowExW(DWORD(WS_EX_TOOLWINDOW), name, title, DWORD(WS_POPUP),
                                -32000, -32000, 1, 1, nil, nil, instance, nil)
            }
        }
        guard let created, let view = WebEngine.makeSandboxView(parent: created) else {
            throw RailScriptError.noPage
        }
        host = created
        webView = view
        return view
    }

    private func registerClass(_ instance: HINSTANCE?) {
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.lpfnWndProc = { hwnd, message, wParam, lParam in
            DefWindowProcW(hwnd, message, wParam, lParam)
        }
        wc.hInstance = instance
        _ = Self.className.withCString(encodedAs: UTF16.self) { name -> ATOM in
            wc.lpszClassName = name
            // Registering twice answers zero and sets `ERROR_CLASS_ALREADY_EXISTS`, which is fine:
            // this is called once, and the class outlives the window either way.
            return RegisterClassExW(&wc)
        }
    }
}
