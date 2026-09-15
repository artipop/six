import AppKit
import SwiftUI

/// six in another app's Share menu.
///
/// The system asks for a view controller and puts its view in a sheet over the app that shared; the
/// view is `ShareSheet`, and everything it decides is sent to six as one `ShareRequest` address. The
/// extension itself reads one file, opens one URL and keeps nothing — see `ShareHandoff` for why the
/// two halves talk that way and not over an App Group.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let model = ShareModel()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let host = NSHostingView(rootView: ShareSheet(model: model))
        // The sheet is as tall as what it has to offer — one profile with two rows is not the same
        // sheet as three profiles with ten — and the system sizes it from this.
        host.sizingOptions = [.preferredContentSize]
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }
}
