import AppKit
import Foundation

/// LaunchServices' side of the app: URLs and files handed to six from outside — a link clicked in
/// Mail, `open -a six …`, a double-clicked `.html`, a Handoff tile from an iPhone — and the switch
/// that makes six the default browser.
///
/// The URLs themselves arrive in `sixApp.body` (`.onOpenURL`, `.onContinueUserActivity`): SwiftUI
/// raises the window and hands them over. That only works because six's scene is a `Window` and not
/// a `WindowGroup` — see the comment there.
enum ExternalOpen {
    /// A `.webloc` is a plist wrapping the URL someone saved; open what it points at, not the file.
    static func resolve(_ url: URL) -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String,
              let target = URL(string: string)
        else { return url }
        return target
    }

    /// macOS hands six the link but leaves whatever app the click came from in front, so the window
    /// asks for the front itself — and a window someone minimised has to be dug out first.
    @MainActor
    static func comeForward() {
        NSApp.activate()
        guard let window = NSApp.windows.first(where: \.canBecomeMain) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ExternalOpenDelegate: NSObject, NSApplicationDelegate {
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
