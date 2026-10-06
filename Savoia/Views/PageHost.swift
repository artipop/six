#if os(macOS)
import SwiftUI
import WebKit

/// Shows a tab's own web view, held by frame.
struct PageHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        mount(in: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        // A view another host has taken since is that host's.
        if view.superview == nil { mount(in: host) }
    }

    private func mount(in host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}
#endif
