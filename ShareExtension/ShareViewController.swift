import AppKit
import OSLog
import SwiftUI

/// six in another app's Share menu.
///
/// The system asks for a view controller and puts its view in a sheet over the app that shared; the
/// view is `ShareSheet`, and everything it decides is sent to six as one `ShareRequest` address. The
/// extension itself reads one file, opens one URL and keeps nothing — see `ShareHandoff` for why the
/// two halves talk that way and not over an App Group.
///
/// **The size is set here, in points, and not left to SwiftUI.** A share sheet is a remote view: the
/// app that shared draws the dimming and asks this process how big its content is, once, before
/// anything of ours has laid out. `NSHostingView.sizingOptions` answers that question through a
/// *hosting controller* which a bare hosting view does not have, so the honest answer was zero — the
/// note dimmed, nothing was drawn over it, and Esc was the only way out (Artem, from Notes). A fixed
/// frame is what a sheet of this kind wants anyway: the one part that grows, the list of workspaces,
/// scrolls inside it.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let model = ShareModel()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "six.share", category: "share")

    /// Points, and a share of nothing: a sheet hangs in another app's window, where six has no
    /// viewport to take a fraction of.
    static let size = NSSize(width: 440, height: 420)

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        // A hosting *controller* as a child, and not a hosting view as the view. The sheet is a remote
        // view: the app that shared owns the window, and what crosses is a view controller. With a bare
        // `NSHostingView` the sheet came up empty — the note dimmed and nothing was drawn over it
        // (Artem, from Notes) — because SwiftUI's own sizing goes through the controller a hosting view
        // does not have, and nothing ever gave the remote view a size.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let host = NSHostingController(rootView: ShareSheet(model: model))
        addChild(host)
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        view = container
        preferredContentSize = Self.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = Self.size
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }

    /// What the sheet actually came up as. The only way to see it from here: a share extension cannot
    /// be screenshotted from this machine, and a sheet that draws nothing and a sheet that was never
    /// asked for look identical from the outside.
    override func viewDidAppear() {
        super.viewDidAppear()
        log.info("sheet shown at \(NSStringFromRect(self.view.frame), privacy: .public); preferred \(NSStringFromSize(self.preferredContentSize), privacy: .public); fitting \(NSStringFromSize(self.view.fittingSize), privacy: .public)")
    }

}
