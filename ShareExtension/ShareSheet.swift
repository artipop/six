import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// What was shared, and where it is going.
@Observable
final class ShareModel {
    enum Content: Equatable {
        /// Still reading what the sharing app handed over.
        case loading
        /// An address on the web: it can be opened, and saved as a bookmark.
        case page(URL)
        /// A file six can show. Opened, never bookmarked — a bookmark is a page re-read from its site.
        case file(URL)
        /// Words: searched for with six's engine, in the chosen workspace.
        case search(String)
        /// Nothing six can do anything with, which the activation rule should have kept from happening.
        case nothing
    }

    var content: Content = .loading
    var title = ""
    /// Nil when six has never run (or never written the file down): the sheet still opens things,
    /// in whatever profile and workspace is in front.
    var targets: ShareTargets?
    var profileID: UUID?
    var workspaceID: UUID?
    /// Set once a button is pressed, so a second press does not send twice while six is launching.
    var isSending = false

    @ObservationIgnored var finish: () -> Void = {}
    @ObservationIgnored var cancel: () -> Void = {}

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "six.share", category: "share")

    var profile: ShareTargets.Profile? {
        targets?.profiles.first { $0.id == profileID }
    }

    /// For the view to say what happened to it, since nothing here can look at the sheet.
    func note(_ message: String) {
        log.info("\(message, privacy: .public)")
    }

    func load(_ items: [NSExtensionItem]) async {
        targets = Self.readTargets()
        let selected = targets?.profiles.first(where: \.isSelected) ?? targets?.profiles.first
        profileID = selected?.id
        workspaceID = selected?.workspaces.first(where: \.isFocused)?.id

        let item = items.first
        title = item?.attributedTitle?.string ?? item?.attributedContentText?.string ?? ""
        content = await Self.read(items)
        if title.isEmpty, case .file(let url) = content { title = url.lastPathComponent }
        log.info("sheet for \(String(describing: self.content), privacy: .private); rail \(self.targets == nil ? "unknown" : "read", privacy: .public)")
    }

    func selectProfile(_ id: UUID) {
        profileID = id
        workspaceID = profile?.workspaces.first(where: \.isFocused)?.id
    }

    func send(_ action: ShareRequest.Action) {
        guard !isSending else { return }
        var request = ShareRequest(action: action, title: title, profileID: profileID, workspaceID: workspaceID)
        switch content {
        case .page(let url), .file(let url): request.url = url
        case .search(let text): request.text = text
        case .loading, .nothing: return cancel()
        }
        let info = Bundle.main.infoDictionary
        let scheme = info?["SixShareScheme"] as? String ?? "six-share"
        guard let address = request.address(scheme: scheme) else { return cancel() }
        isSending = true

        // To the app this extension is inside, by path, and not to whichever copy of six claims the
        // scheme: a development build and the installed one both carry a sheet, and each one's sheet
        // belongs to its own app. `…/six.app/Contents/PlugIns/six-share.appex` is three levels down.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        // A bookmark is saved from where it was shared; six has no reason to take the front for it.
        configuration.activates = action != .bookmark
        let finish = finish
        let log = log
        NSWorkspace.shared.open([address], withApplicationAt: app, configuration: configuration) { _, error in
            if let error {
                log.error("handoff to \(app.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                NSWorkspace.shared.open(address)
            }
            DispatchQueue.main.async { finish() }
        }
    }

    // MARK: Reading

    /// The first attachment six can use, in the order that keeps a file a file: a file URL before its
    /// own type (a text file shared from Finder registers `public.plain-text` too), an address before
    /// text (Safari hands over both), and text last.
    private static func read(_ items: [NSExtensionItem]) async -> Content {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadURL(provider, type: .fileURL), url.isFileURL { return .file(url) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider, type: .url) { return url.isFileURL ? .file(url) : .page(url) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(provider), let content = classify(text) { return content }
        }
        return .nothing
    }

    /// Text that *is* an address is an address — a link copied out of a chat arrives as text. Anything
    /// with more in it than one address is a query, the way the address bar reads it.
    static func classify(_ raw: String) -> Content? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains(where: \.isWhitespace) {
            if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
                return .page(url)
            }
            if text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), let url = URL(string: "https://\(text)"), url.host() != nil {
                return .page(url)
            }
        }
        return .search(text)
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                switch value {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                case let string as String: continuation.resume(returning: URL(string: string))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                switch value {
                case let string as String: continuation.resume(returning: string)
                case let text as NSAttributedString: continuation.resume(returning: text.string)
                case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The file six keeps for this sheet, from the real home folder: inside the sandbox
    /// `NSHomeDirectory()` is the extension's container, and the entitlement names the path under the
    /// person's own `~/Library`.
    private static func readTargets() -> ShareTargets? {
        guard let identifier = Bundle.main.infoDictionary?["SixAppIdentifier"] as? String,
              let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        let url = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Library/Application Support/\(identifier)/\(ShareTargets.fileName)")
        guard let data = try? Data(contentsOf: url),
              let targets = try? JSONDecoder().decode(ShareTargets.self, from: data),
              !targets.profiles.isEmpty else { return nil }
        return targets
    }
}

/// The sheet: what is being shared, which workspace it goes to, and what to do with it.
///
/// The choices are Chrome's on the phone, which asks the same question: open it, open it privately,
/// or save it for later. Save is six's bookmark rather than a reading list, and it goes to the
/// profile the chosen workspace belongs to — bookmarks are kept per profile, so the workspace decides
/// whose they are.
struct ShareSheet: View {
    @Bindable var model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if case .nothing = model.content {
                Text("six can't open what was shared.")
                    .foregroundStyle(.secondary)
            } else {
                destination
            }
            Spacer(minLength: 0)
            Divider()
            buttons
        }
        .padding(16)
        // The controller's size, filled from the top: a sheet in somebody else's window cannot grow
        // to fit, so the list of workspaces scrolls and everything else keeps its place.
        .frame(width: ShareViewController.size.width, height: ShareViewController.size.height, alignment: .topLeading)
        // What SwiftUI itself made of it. The AppKit side can report a view of the right size around a
        // body that laid out as nothing, and from here neither a screenshot nor a click is available.
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { model.note("body laid out at \(proxy.size.width)×\(proxy.size.height)") }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var destination: some View {
        if let targets = model.targets {
            if targets.profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { model.profileID ?? UUID() }, set: { model.selectProfile($0) })) {
                    ForEach(targets.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let profile = model.profile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(profile.workspaces.enumerated()), id: \.element.id) { index, workspace in
                                WorkspaceRow(workspace: workspace, index: index, color: Color(hex: profile.colorHex),
                                             isSelected: workspace.id == model.workspaceID) {
                                    model.workspaceID = workspace.id
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("It opens in the workspace that is in front. Start six once and its workspaces are offered here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isSending { ProgressView().controlSize(.small) }
            Button {
                model.send(.openPrivate)
            } label: {
                Image(systemName: "hand.raised")
            }
            .help("Open in Private Window")
            .disabled(!canOpen)
            if case .page = model.content {
                Button("Add to Bookmarks") { model.send(.bookmark) }
                    .help(model.profile.map { String(localized: "Saves the page to the bookmarks of \($0.name)") } ?? "")
                    .disabled(model.isSending)
            }
            Button(isSearch ? "Search" : "Open") { model.send(.open) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canOpen)
        }
    }

    private var canOpen: Bool {
        switch model.content {
        case .page, .file, .search: !model.isSending
        case .loading, .nothing: false
        }
    }

    private var isSearch: Bool {
        if case .search = model.content { return true }
        return false
    }

    private var icon: String {
        switch model.content {
        case .loading, .page: "globe"
        case .file: "doc"
        case .search: "magnifyingglass"
        case .nothing: "questionmark"
        }
    }

    private var headline: String {
        switch model.content {
        case .loading: return model.title
        case .page(let url): return model.title.isEmpty ? (url.host() ?? url.absoluteString) : model.title
        case .file(let url): return model.title.isEmpty ? url.lastPathComponent : model.title
        case .search(let text): return text
        case .nothing: return model.title
        }
    }

    private var detail: String {
        switch model.content {
        case .page(let url): url.absoluteString
        case .file(let url): url.deletingLastPathComponent().path
        case .search: String(localized: "Search the web")
        case .loading, .nothing: ""
        }
    }
}

private struct WorkspaceRow: View {
    let workspace: ShareTargets.Workspace
    let index: Int
    let color: Color
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if workspace.isFocused {
                    Text("In front")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? AnyShapeStyle(color.opacity(0.15)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// The rail's own words: the name, or the position — and the empty row below the others, which is
    /// where a new workspace comes from, called what it is.
    private var name: String {
        if !workspace.name.isEmpty { return workspace.name }
        if workspace.windowCount == 0 { return String(localized: "New Workspace") }
        return String(localized: "Workspace \(index + 1)")
    }

    private var summary: String {
        guard workspace.windowCount > 0 else { return "" }
        let titles = workspace.pages.joined(separator: " · ")
        let more = workspace.windowCount - workspace.pages.count
        guard more > 0 else { return titles }
        return titles.isEmpty ? String(localized: "\(workspace.windowCount) windows") : titles + " " + String(localized: "+\(more) more")
    }
}

private extension Color {
    /// `#RRGGBB`, the way a profile's colour is stored.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0x808080
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
