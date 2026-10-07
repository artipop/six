#if os(macOS)
import AppKit
import Foundation
import WebKit

/// A dialog a page is waiting on: `alert()`, `confirm()`, `prompt()`, or the file picker behind
/// `<input type="file">`. The person answers it at its sheet, an agent through the tab — whichever
/// comes first. docs/agent-actions.md.
@MainActor
final class PageDialog {
    enum Kind: String { case alert, confirm, prompt, files }
    enum Answer {
        /// The text is a prompt's; nil leaves what the field holds.
        case accepted(String?)
        case dismissed
        case files([URL])
    }

    let kind: Kind
    let message: String
    /// Empty for a page with no host of its own.
    let host: String
    let defaultText: String?
    let panel: WKOpenPanelParameters?
    /// Text set ahead of an accept, as WebDriver does it.
    var input: String?
    fileprivate var finish: ((Answer) -> Void)?
    fileprivate var closeSheet: (() -> Void)?

    fileprivate init(kind: Kind, message: String, host: String, defaultText: String?, panel: WKOpenPanelParameters?) {
        self.kind = kind
        self.message = message
        self.host = host
        self.defaultText = defaultText
        self.panel = panel
    }

    /// `alert`, `confirm` and `prompt` hold the page's script until they are answered.
    var stopsScript: Bool { kind != .files }

    func resolve(_ answer: Answer) {
        guard let finish else { return }
        self.finish = nil
        finish(answer)
        closeSheet?()
        closeSheet = nil
    }

    /// For a model, so in English.
    var summary: String {
        let from = host.isEmpty ? "the page" : host
        switch kind {
        case .files: return "a file chooser from \(from)"
        case .prompt: return "prompt \"\(message)\" from \(from), holding \"\(input ?? defaultText ?? "")\""
        default: return "\(kind.rawValue) \"\(message)\" from \(from)"
        }
    }
}

/// The dialogs one tab's page has open, and the files an agent named for a chooser about to open.
@MainActor
final class PendingDialogs {
    private(set) var open: [PageDialog] = []
    private var watchers: [UUID: () -> Void] = [:]
    private var offer: (key: UUID, urls: [URL], taken: (String?) -> Void)?

    var stoppingScript: PageDialog? { open.last { $0.stopsScript } }
    var fileChooser: PageDialog? { open.last { $0.kind == .files } }

    func ask(_ kind: PageDialog.Kind, message: String = "", defaultText: String? = nil, panel: WKOpenPanelParameters? = nil,
             from origin: WKSecurityOrigin, on window: NSWindow?) async -> PageDialog.Answer {
        if let panel, let offer {
            self.offer = nil
            let misfit = Self.misfit(offer.urls, panel)
            offer.taken(misfit)
            return misfit == nil ? .files(offer.urls) : .dismissed
        }
        return await withCheckedContinuation { continuation in
            let dialog = PageDialog(kind: kind, message: message, host: origin.host, defaultText: defaultText, panel: panel)
            dialog.finish = { [weak self, weak dialog] answer in
                self?.open.removeAll { $0 === dialog }
                continuation.resume(returning: answer)
            }
            open.append(dialog)
            if dialog.stopsScript {
                let waiting = watchers
                watchers = [:]
                waiting.values.forEach { $0() }
            }
            PageDialogs.present(dialog, on: window)
        }
    }

    /// The work's answer, or nil once a dialog holds the page's script under it; the work then ends unheard.
    func racing(_ work: @escaping () async throws -> String) async throws -> String? {
        guard stoppingScript == nil else { return nil }
        let key = UUID()
        let result: Result<String, any Error>? = await withCheckedContinuation { continuation in
            watchers[key] = { continuation.resume(returning: nil) }
            Task {
                let result: Result<String, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if self.watchers.removeValue(forKey: key) != nil { continuation.resume(returning: result) }
            }
        }
        return try result?.get()
    }

    /// Answers the chooser that `open` brings up with these files, with no panel. Nil when the page
    /// took them, else why not.
    func choosing(_ urls: [URL], by open: @escaping () async throws -> Void) async throws -> String? {
        let key = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            offer = (key, urls, { continuation.resume(returning: $0) })
            Task {
                do {
                    try await open()
                } catch {
                    if self.withdraw(key) { continuation.resume(throwing: error) }
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                if self.withdraw(key) { continuation.resume(returning: "it opened no file chooser") }
            }
        }
    }

    private func withdraw(_ key: UUID) -> Bool {
        guard offer?.key == key else { return false }
        offer = nil
        return true
    }

    static func misfit(_ urls: [URL], _ panel: WKOpenPanelParameters) -> String? {
        if urls.count > 1, !panel.allowsMultipleSelection { return "it takes one file, not \(urls.count)" }
        let folders = urls.filter(\.hasDirectoryPath)
        if panel.allowsDirectories, folders.count < urls.count { return "it takes a folder, not a file" }
        if !panel.allowsDirectories, !folders.isEmpty { return "it takes files, not a folder" }
        return nil
    }

    func dismissAll() {
        open.forEach { $0.resolve(.dismissed) }
    }
}

/// The sheets. Every one says which site it came from: the window holds many pages, and the one
/// that asked is often not the one being looked at.
@MainActor
enum PageDialogs {
    fileprivate static func present(_ dialog: PageDialog, on window: NSWindow?) {
        if let parameters = dialog.panel {
            present(dialog, choosing: parameters, on: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(host(dialog.host)) says:")
        alert.informativeText = dialog.message
        alert.addButton(withTitle: String(localized: "OK"))
        if dialog.kind != .alert { alert.addButton(withTitle: String(localized: "Cancel")) }
        var field: NSTextField?
        if dialog.kind == .prompt {
            let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            text.stringValue = dialog.defaultText ?? ""
            alert.accessoryView = text
            // Without this the sheet opens with the buttons focused.
            alert.window.initialFirstResponder = text
            field = text
        }
        let answer: (NSApplication.ModalResponse) -> PageDialog.Answer = {
            $0 == .alertFirstButtonReturn ? .accepted(field?.stringValue) : .dismissed
        }
        // No window to hang a sheet on, and the dialog still has to be answerable.
        guard let window else { return dialog.resolve(answer(alert.runModal())) }
        dialog.closeSheet = { [weak window] in window?.endSheet(alert.window) }
        alert.beginSheetModal(for: window) { response in
            dialog.closeSheet = nil
            dialog.resolve(answer(response))
        }
    }

    private static func present(_ dialog: PageDialog, choosing parameters: WKOpenPanelParameters, on window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        // `webkitdirectory` asks for a folder and nothing else; an ordinary input asks for files.
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.message = String(localized: "\(host(dialog.host)) is asking for a file.")
        panel.prompt = String(localized: "Choose")
        let answer: (NSApplication.ModalResponse) -> PageDialog.Answer = { $0 == .OK ? .files(panel.urls) : .dismissed }
        guard let window else { return dialog.resolve(answer(panel.runModal())) }
        dialog.closeSheet = { panel.cancel(nil) }
        panel.beginSheetModal(for: window) { response in
            dialog.closeSheet = nil
            dialog.resolve(answer(response))
        }
    }

    /// The site behind the frame that asked — a subframe's own origin, not the page's.
    static func host(_ host: String) -> String {
        host.isEmpty ? String(localized: "This page") : host
    }

    static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }
}
#endif
