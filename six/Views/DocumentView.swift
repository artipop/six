import SwiftUI
import WebKit

/// A document column: the Markdown source in a text editor, or the rendered preview in the tab's
/// own `WebPage`. The two swap in place — the column stays — and the preview page is also what
/// exports the document as HTML or PDF.
struct DocumentView: View {
    let tab: BrowserTab
    let document: TextDocument
    let isActive: Bool

    @Environment(BrowserState.self) private var browser
    @State private var rendered = ""

    var body: some View {
        Group {
            if document.showsPreview {
                WebView(tab.page)
                    .id(tab.id)
            } else {
                Editor(document: document, isActive: isActive)
            }
        }
        .task(id: document.showsPreview) {
            guard document.showsPreview else { return }
            render(force: true)
        }
        .onChange(of: document.text) {
            guard document.showsPreview else { return }
            render(force: false)
        }
    }

    private func render(force: Bool) {
        let html = Markdown.page(title: document.title, markdown: document.text)
        guard force || html != rendered else { return }
        rendered = html
        _ = tab.page.load(html: html, baseURL: URL(string: "six://document/\(document.id.uuidString)/")!)
    }

    /// Plain `TextEditor` over the source. The agent writes by section and never touches the section
    /// the cursor is in (see `write_document`), so one binding is enough for two writers.
    private struct Editor: View {
        @Bindable var document: TextDocument
        let isActive: Bool
        @FocusState private var focused: Bool

        var body: some View {
            TextEditor(text: $document.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor))
                .focused($focused)
                .onAppear { if isActive, document.text.isEmpty { focused = true } }
        }
    }
}
