#if os(macOS)
import SwiftUI
import WebKit

/// Shows a tab's own web view, held by frame.
struct PageHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.page = view
        Self.mount(view, in: host)
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        // A view another host has taken since is that host's.
        if view.superview == nil { Self.mount(view, in: host) }
        // SwiftUI may rebuild the responder chain; the fallback rejoins it.
        PageKeyFallback.install(on: view)
    }

    final class Host: NSView {
        weak var page: WKWebView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let page { PageKeyFallback.install(on: page) }
        }

        /// WebKit takes its fullscreen placeholder out and does not always put the page back.
        override func willRemoveSubview(_ subview: NSView) {
            super.willRemoveSubview(subview)
            if subview !== page { Task { self.takeBack() } }
        }

        private func takeBack() {
            guard window != nil, subviews.isEmpty, let page, page.fullscreenState == .notInFullscreen else { return }
            PageHost.mount(page, in: self)
        }
    }

    fileprivate static func mount(_ view: WKWebView, in host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}
#endif
