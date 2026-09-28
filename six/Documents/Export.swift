#if os(macOS)
import AppKit
#endif
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
        /// What the server sent, byte for byte — a raw log, a JSON reply, an image. Offered only for
        /// a page that is not HTML; its type is the one WebKit reports for the document.
        case original

        var id: String { rawValue }

        var type: UTType {
            switch self {
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .html: .html
            case .pdf: .pdf
            case .text: .plainText
            case .original: .data
            }
        }

        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .html: "HTML"
            case .pdf: "PDF"
            case .text: "Plain Text"
            case .original: "Original"
            }
        }

        static func formats(for tab: BrowserTab, served: UTType? = nil) -> [Format] {
            if tab.isDocument { return [.markdown, .html, .pdf] }
            return served == nil ? [.html, .pdf, .text] : [.original, .pdf, .text]
        }

        static func format(for url: URL, of tab: BrowserTab, served: UTType? = nil) -> Format {
            let ext = url.pathExtension.lowercased()
            let formats = formats(for: tab, served: served)
            return formats.first { format in
                let type = format == .original ? served ?? .data : format.type
                return type.preferredFilenameExtension == ext || type.tags[.filenameExtension]?.contains(ext) == true
                    || (format == .markdown && ext == "markdown")
            } ?? formats[0]
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
        #if os(iOS)
        // No panel on the phone: the file lands in the app's own Documents folder, which is what
        // `UIFileSharingEnabled` puts in front of the Files app.
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let served = await servedType(of: tab)
        let format = Format.formats(for: tab, served: served)[0]
        let type = format == .original ? served ?? .data : format.type
        let url = folder.appending(path: suggestedName(for: tab) + "." + (type.preferredFilenameExtension ?? "txt"))
        try? await write(tab, to: url, as: format)
        #elseif os(macOS)
        let served = await servedType(of: tab)
        let panel = NSSavePanel()
        let types = Format.formats(for: tab, served: served).map { $0 == .original ? served ?? .data : $0.type }
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName(for: tab) + "." + (types[0].preferredFilenameExtension ?? "txt")
        panel.directoryURL = tab.document?.fileURL?.deletingLastPathComponent() ?? lastFolder
        panel.title = String(localized: "Save As")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastFolder = url.deletingLastPathComponent()
        do {
            try await write(tab, to: url, as: Format.format(for: url, of: tab, served: served))
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't save \(url.lastPathComponent)"
            alert.runModal()
        }
        #endif
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
            case .markdown, .text, .original:
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
        case .original:
            return try await original(of: tab)
        }
    }

    /// The document's type as WebKit took it from the response, or nil for an HTML page.
    private static func servedType(of tab: BrowserTab) async -> UTType? {
        guard !tab.isDocument, !tab.showsStartPage,
              let mime = (try? await tab.page.six("return document.contentType")) as? String,
              !["text/html", "application/xhtml+xml"].contains(mime) else { return nil }
        return UTType(mimeType: mime) ?? .data
    }

    /// Text WebKit shows as a single `<pre>` is read back from the page: a raw CI log's link is signed
    /// and short-lived, so asking the server again can fail. Anything else is fetched with the
    /// profile's cookies.
    private static func original(of tab: BrowserTab) async throws -> Data {
        let script = """
        const pre = document.body?.children.length === 1 ? document.body.firstElementChild : null
        return pre?.tagName === 'PRE' ? pre.textContent : null
        """
        if let text = (try? await tab.page.six(script)) as? String { return Data(text.utf8) }
        guard let url = tab.currentURL else { throw URLError(.badURL) }
        let request = await DownloadStore.outgoing(URLRequest(url: url), referrer: nil, cookies: tab.dataStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
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
