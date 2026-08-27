import AppKit
import Foundation

/// LaunchServices' side of the app: URLs and files handed to six from outside — a link clicked in
/// Mail, `open -a six …`, a double-clicked `.html` — and the switch that makes six the default browser.
///
/// An event can land before `sixApp.init` has built the browser (a launch caused *by* the URL), so
/// anything arriving early waits in `pending` until the handler is set.
@MainActor
final class ExternalOpenDelegate: NSObject, NSApplicationDelegate {
    static var handler: ((URL) -> Void)? {
        didSet {
            guard handler != nil, !pending.isEmpty else { return }
            let queued = pending
            pending = []
            deliver(queued)
        }
    }

    private static var pending: [URL] = []

    static func deliver(_ urls: [URL]) {
        guard let handler else {
            pending.append(contentsOf: urls)
            return
        }
        for url in urls { handler(resolve(url)) }
        NSApp.activate()
    }

    /// A `.webloc` is a plist wrapping the URL someone saved; open what it points at, not the file.
    private static func resolve(_ url: URL) -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String,
              let target = URL(string: string)
        else { return url }
        return target
    }

    /// SwiftUI answers an external open by asking its window controller for a window, and for six
    /// that is a crash: a second window would put the same `WebPage`s into a second `WebView`, which
    /// WebKit traps on. Taking the `GetURL` Apple Event — the one AppKit turns into
    /// `application(_:open:)` — keeps that machinery out of it entirely. Registered before AppKit
    /// hands over the event it was launched with, and again once SwiftUI has had its turn.
    func applicationWillFinishLaunching(_ notification: Notification) {
        claimGetURL()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        claimGetURL()
        DispatchQueue.main.async { self.claimGetURL() }
    }

    private func claimGetURL() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let direct = event.paramDescriptor(forKeyword: keyDirectObject)
        let items = (direct?.numberOfItems ?? 0) > 1
            ? (1...direct!.numberOfItems).compactMap { direct!.atIndex($0) }
            : [direct].compactMap { $0 }
        Self.deliver(items.compactMap { $0.stringValue.flatMap(URL.init(string:)) })
    }

    /// The window's state is restored from six's own snapshot, not AppKit's archive; saying so
    /// silences the launch warning.
    func applicationSupportsSecureRestorableState(_ application: NSApplication) -> Bool { true }
}

/// Whether macOS sends the web to six, and asking it to.
enum DefaultBrowser {
    private static let probe = URL(string: "https://example.com")!
    private static let schemes = ["http", "https"]

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS puts up its own confirmation: an app cannot make itself the default silently, and
    /// shouldn't be able to.
    static func makeDefault() async {
        for scheme in schemes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            } catch {
                FileHandle.standardError.write(Data("[six] default browser (\(scheme)): \(error)\n".utf8))
            }
        }
    }
}
