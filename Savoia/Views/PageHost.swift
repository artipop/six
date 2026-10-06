#if os(macOS)
import SwiftUI
import WebKit

/// Shows a tab's own web view, held by frame.
struct PageHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.page = view
        mount(in: host)
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        // A view another host has taken since is that host's.
        if view.superview == nil { mount(in: host) }
        // SwiftUI may rebuild the responder chain; the fallback rejoins it.
        PageKeyFallback.install(on: view)
    }

    final class Host: NSView {
        weak var page: WKWebView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let page { PageKeyFallback.install(on: page) }
        }
    }

    private func mount(in host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}
#endif
