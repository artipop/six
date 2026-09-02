#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The phone's whole window: the strip, and the little chrome a phone can spare for it.
///
/// The Mac puts its controls in a menu bar and a top bar. A phone has neither to give away, so the
/// same commands live in one bar at the bottom — where a thumb is — and everything that is a sheet
/// on the Mac is a sheet here too, unchanged.
struct PhoneContentView: View {
    @Environment(BrowserState.self) private var browser
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var showFilterLists = false
    @State private var showExtensions = false
    @State private var showSitePermissions = false
    @State private var showCertificates = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            PhoneStripView()
            PhoneToolbar(showHistory: $showHistory,
                         showBookmarks: $showBookmarks,
                         showFilterLists: $showFilterLists,
                         showExtensions: $showExtensions,
                         showSitePermissions: $showSitePermissions,
                         showCertificates: $showCertificates,
                         confirmClearHistory: $confirmClearHistory)
        }
        .tint(browser.selectedProfile.color)
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(isPresented: $showBookmarks) { BookmarksView() }
        .sheet(isPresented: $showFilterLists) { BlockingView() }
        .sheet(isPresented: $showExtensions) { ExtensionsView() }
        .sheet(isPresented: $showSitePermissions) { PermissionsView() }
        .sheet(isPresented: $showCertificates) { CertificatesView() }
        .clearHistoryDialog(isPresented: $confirmClearHistory)
        .pageDialogs()
    }
}

/// One bar, at the bottom: where the window is, and what can be done to the strip.
private struct PhoneToolbar: View {
    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showFilterLists: Bool
    @Binding var showExtensions: Bool
    @Binding var showSitePermissions: Bool
    @Binding var showCertificates: Bool
    @Binding var confirmClearHistory: Bool

    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        let tab = browser.selectedTab

        HStack(spacing: 4) {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(tab?.canGoBack != true)
            Button { tab?.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(tab?.canGoForward != true)

            Spacer(minLength: 0)

            Button { browser.newTab() } label: { Image(systemName: "plus.square.on.square") }
            Button { browser.toggleOverview() } label: {
                Image(systemName: browser.layout.isOverview ? "square.grid.2x2.fill" : "square.grid.2x2")
            }

            Menu {
                Button("New Window on the Rail", systemImage: "plus") { browser.newTab() }
                Button("New Private Window", systemImage: "hand.raised") { _ = browser.newPrivateWindow() }
                Divider()
                Button("Bookmarks…", systemImage: "book") { showBookmarks = true }
                Button("History…", systemImage: "clock") { showHistory = true }
                Button("Filter Lists…", systemImage: "shield") { showFilterLists = true }
                Button("Extensions…", systemImage: "puzzlepiece.extension") { showExtensions = true }
                Button("Site Permissions…", systemImage: "checkmark.shield") { showSitePermissions = true }
                Button("Certificates…", systemImage: "checkmark.seal") { showCertificates = true }
                Divider()
                if let tab, !tab.showsStartPage {
                    Button("Add Bookmark", systemImage: "star") { Task { try? await bookmarks.add(tab) } }
                }
                Button("Clear History…", systemImage: "trash", role: .destructive) { confirmClearHistory = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
    }
}

/// `alert()`, `confirm()`, `prompt()` and `<input type="file">`, put up over the whole window: one
/// at a time, each saying which site it came from.
private struct PageDialogHost: ViewModifier {
    @State private var queue = PageDialogQueue.shared
    @State private var reply = ""
    @State private var importing = false

    func body(content: Content) -> some View {
        let request = queue.current
        let isFile: Bool = if case .file = request?.kind { true } else { false }

        content
            .alert(request.map { "\($0.host) says:" } ?? "", isPresented: Binding(
                get: { request != nil && !isFile },
                set: { if !$0 { queue.resolve(.cancel) } }
            ), presenting: request) { request in
                if case .prompt(let defaultText) = request.kind {
                    TextField("", text: $reply)
                        .onAppear { reply = defaultText }
                    Button("OK") { queue.resolve(.ok(reply)) }
                    Button("Cancel", role: .cancel) { queue.resolve(.cancel) }
                } else if case .confirm = request.kind {
                    Button("OK") { queue.resolve(.ok("")) }
                    Button("Cancel", role: .cancel) { queue.resolve(.cancel) }
                } else {
                    Button("OK") { queue.resolve(.ok("")) }
                }
            } message: { request in
                Text(request.message)
            }
            .onChange(of: isFile, initial: true) { _, wantsFile in importing = wantsFile }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: {
                              if case .file(let multiple, _) = request?.kind { multiple } else { false }
                          }()) { result in
                switch result {
                case .success(let urls): queue.resolve(.files(Self.copyIntoTemporary(urls)))
                case .failure: queue.resolve(.cancel)
                }
            }
    }

    /// The picker hands back security-scoped URLs, which stop being readable the moment the scope
    /// closes; WebKit reads them later, on its own schedule. A copy in our own temporary folder is
    /// ours to hand over.
    private static func copyIntoTemporary(_ urls: [URL]) -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "uploads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = folder.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            } catch {
                return nil
            }
        }
    }
}

extension View {
    func pageDialogs() -> some View { modifier(PageDialogHost()) }
}
#endif
