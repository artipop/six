import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Save As for both kinds of window. The app is not sandboxed, so an `NSSavePanel` and a plain write
/// are all it takes; the last folder is remembered, and a document remembers its own file so that
/// ⌘S afterwards is a re-save without a panel.
@MainActor
enum Exporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown, html, pdf, text

        var id: String { rawValue }

        var type: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .html: .html
            case .pdf: .pdf
            case .text: .plainText
            }
        }

        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .html: "HTML"
            case .pdf: "PDF"
            case .text: "Plain Text"
            }
        }

        static func formats(for tab: BrowserTab) -> [Format] {
            tab.isDocument ? [.markdown, .html, .pdf] : [.html, .pdf, .text]
        }

        static func format(for url: URL, of tab: BrowserTab) -> Format {
            let ext = url.pathExtension.lowercased()
            return formats(for: tab).first { $0.type.preferredFilenameExtension == ext || ($0 == .markdown && ext == "markdown") }
                ?? formats(for: tab)[0]
        }
    }

    private static let lastFolderKey = "six.export.lastFolder"

    static var lastFolder: URL? {
        get { UserDefaults.standard.url(forKey: lastFolderKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastFolderKey) }
    }

    /// ⌘S: a document that has a file goes straight back to it; anything else asks where.
    static func save(_ tab: BrowserTab) async {
        if let document = tab.document, let url = document.fileURL {
            do {
                try await write(tab, to: url, as: Format.format(for: url, of: tab))
            } catch {
                await saveAs(tab)
            }
            return
        }
        await saveAs(tab)
    }

    /// ⌘⇧S: the panel, with the formats the window can be saved as.
    static func saveAs(_ tab: BrowserTab) async {
        let panel = NSSavePanel()
        let formats = Format.formats(for: tab)
        panel.allowedContentTypes = formats.map(\.type)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName(for: tab) + "." + (formats[0].type.preferredFilenameExtension ?? "txt")
        panel.directoryURL = tab.document?.fileURL?.deletingLastPathComponent() ?? lastFolder
        panel.title = String(localized: "Save As")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.deletingLastPathComponent()
        do {
            try await write(tab, to: url, as: Format.format(for: url, of: tab))
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't save \(url.lastPathComponent)"
            alert.runModal()
        }
    }

    private static func suggestedName(for tab: BrowserTab) -> String {
        if let document = tab.document { return document.suggestedFileName }
        let title = tab.title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? (tab.currentURL?.host() ?? "Page") : String(title.prefix(80))
    }

    static func write(_ tab: BrowserTab, to url: URL, as format: Format) async throws {
        let data = try await data(of: tab, as: format)
        try data.write(to: url, options: .atomic)
        if let document = tab.document, format == .markdown { document.fileURL = url }
    }

    /// The bytes of a window in a format. A document's HTML and PDF come through its preview page —
    /// rendering is what a browser does — so the export matches what the preview shows.
    static func data(of tab: BrowserTab, as format: Format) async throws -> Data {
        if let document = tab.document {
            switch format {
            case .markdown, .text:
                return Data(document.text.utf8)
            case .html:
                return Data(Markdown.page(title: document.title, markdown: document.text).utf8)
            case .pdf:
                let page = tab.page
                let html = Markdown.page(title: document.title, markdown: document.text)
                // The preview may not be loaded (the editor is showing); load it and wait.
                _ = page.load(html: html, baseURL: URL(string: "six://document/\(document.id.uuidString)/")!)
                await waitForLoad(page)
                return try await page.exported(as: .pdf())
            }
        }
        tab.resumeIfNeeded()
        await waitForLoad(tab.page)
        switch format {
        case .html:
            let source = (try? await tab.page.six("return '<!DOCTYPE html>\\n' + document.documentElement.outerHTML")) as? String ?? ""
            return Data(source.utf8)
        case .pdf:
            return try await tab.page.exported(as: .pdf())
        case .text, .markdown:
            let text = await BrowserToolCatalog.pageText(of: tab.page) ?? ""
            return Data(text.utf8)
        }
    }

    private static func waitForLoad(_ page: WebPage, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(150))
        while page.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// File menu: documents and saving.
struct FileCommands: Commands {
    let browser: BrowserState
    let highlights: HighlightStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Document") { browser.newDocument() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Save…") { if let tab = browser.selectedTab { Task { await Exporter.save(tab) } } }
                .keyboardShortcut("s")
                .disabled(!canSave)
            Button("Save As…") { if let tab = browser.selectedTab { Task { await Exporter.saveAs(tab) } } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!canSave)
            Divider()
            Button("Highlight Selection") {
                guard let tab = browser.selectedTab else { return }
                Task { _ = await highlights.highlightSelection(in: tab) }
            }
            .keyboardShortcut("h", modifiers: [.option, .shift])
            .disabled(browser.selectedTab.map { $0.isDocument || $0.showsStartPage } ?? true)
            Button("Remove Highlights on This Page") {
                guard let tab = browser.selectedTab, let url = tab.currentURL else { return }
                highlights.removeAll(for: url)
                _ = tab.page.reload()
            }
            .disabled(browser.selectedTab.flatMap(\.currentURL).map { highlights.highlights(for: $0).isEmpty } ?? true)
        }
    }

    private var canSave: Bool {
        guard let tab = browser.selectedTab else { return false }
        return tab.isDocument || !tab.showsStartPage
    }
}
