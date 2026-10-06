#if os(macOS)
import AppKit
import Foundation
import WebKit

/// The four dialogs a page can put up: `alert()`, `confirm()`, `prompt()`, and the file picker
/// behind `<input type="file">`.
///
/// A `WebPage` with no presenter answers all four itself, and its answer is always no — alerts
/// vanish unseen, `confirm()` returns false, and the file picker never opens. That is not a policy,
/// it is a browser that quietly cannot upload a file, which is why Savoia presents them.
///
/// **Sheets, not modal alerts, and every one says which site it came from.** The strip is a single
/// AppKit window holding as many pages as there are columns, so the page that asked is often not the
/// column being looked at; a dialog with no return address would be a demand from nowhere. WebKit
/// suspends the page's JavaScript until these return, which is exactly the contract `alert()` has
/// always had — but it is one column's JavaScript, not the app's.
@MainActor
enum PageDialogs {
    static func alert(_ message: String, from origin: WKSecurityOrigin, on window: NSWindow?) async {
        let alert = Self.alert(from: origin, message: message)
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await present(alert, on: window)
    }

    static func confirm(_ message: String, from origin: WKSecurityOrigin, on window: NSWindow?) async -> Bool {
        let alert = Self.alert(from: origin, message: message)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await present(alert, on: window) == .alertFirstButtonReturn
    }

    static func prompt(_ message: String, defaultText: String?, from origin: WKSecurityOrigin,
                       on window: NSWindow?) async -> String? {
        let alert = Self.alert(from: origin, message: message)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        // Without this the sheet opens with the buttons focused and the field — the only reason the
        // sheet exists — waiting for a click.
        alert.window.initialFirstResponder = field
        return await present(alert, on: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func files(_ parameters: WKOpenPanelParameters, from origin: WKSecurityOrigin,
                      on window: NSWindow?) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        // `webkitdirectory` asks for a folder and nothing else; an ordinary input asks for files.
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.message = String(localized: "\(host(of: origin)) is asking for a file.")
        panel.prompt = String(localized: "Choose")
        guard let window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls : nil
    }

    // MARK: Presenting

    private static func alert(from origin: WKSecurityOrigin, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(host(of: origin)) says:")
        alert.informativeText = message
        return alert
    }

    /// The site behind the frame that asked — a subframe's own origin, not the page's, because that
    /// is who is speaking.
    static func host(of origin: WKSecurityOrigin) -> String {
        origin.host.isEmpty ? String(localized: "This page") : origin.host
    }

    static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    static func present(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        // No window to hang a sheet on — during a launch, or with every window closed — and the
        // dialog still has to be answerable, so it runs on its own.
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
#endif
