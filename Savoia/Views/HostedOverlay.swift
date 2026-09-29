#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI hosted in an AppKit view, so it stands *beside* a `WKWebView` in the view hierarchy instead
/// of being drawn over it — the difference between a control that works over a page and one that looks
/// like it should.
struct HostedOverlay<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        // Frame-driven, never constraint-driven. A hosting view that publishes its own size inside a
        // SwiftUI window feeds constraints back into it, and the window's update passes never settle:
        // "marked as needing another Update Constraints in Window pass" — and then it throws.
        view.sizingOptions = []
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) { view.rootView = content }
}
#endif
