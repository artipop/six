#if os(macOS)
import SwiftUI

/// six's settings, at `six://settings`.
///
/// A **page**, for the reason `BuiltInPage` gives: it opens in a column of the rail, so the thing a
/// setting is about can stay open beside it. Reading what a site is allowed while looking at the
/// site is the case that settles the argument — a sheet covers the window it is asking about.
///
/// It is also where the menu bar went. six had thirteen menus, five of which were one feature each
/// with a switch in it, and a person looking for "does this block ads" had no reason to look under
/// *Privacy* rather than *Develop*. What is left in the menus is what a menu is for — things you
/// *do*, with a key beside them. What settled into a state and stayed there is here.
struct ConfigurationPageView: View {
    /// The window this page is in, so the header can name it the way every built-in page does.
    let tab: BrowserTab

    @State private var section: Section = .general

    /// The order is how often you touch them, not how important they are.
    enum Section: String, CaseIterable, Identifiable {
        case general
        case windows
        case privacy
        case assistant
        case extensions
        case develop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .windows: String(localized: "Windows")
            case .privacy: String(localized: "Privacy")
            case .assistant: String(localized: "Assistant")
            case .extensions: String(localized: "Extensions")
            case .develop: String(localized: "Develop")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .windows: "rectangle.split.3x1"
            case .privacy: "hand.raised"
            case .assistant: "sparkles"
            case .extensions: "puzzlepiece.extension"
            case .develop: "hammer"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                detail
            }
        }
        .background(.background)
        // The address and the sidebar are the same fact. Arriving with `#assistant` turns the page to
        // it, and turning it by hand rewrites the address — so the window can be copied, typed again
        // or restored where it stood, which one address for six panes could not do.
        .onAppear { if let named = Self.pane(of: tab.section) { section = named } }
        .onChange(of: tab.section) {
            if let named = Self.pane(of: tab.section), named != section { section = named }
        }
        // Only the first word is this view's to write: a pane that keeps a part of its own owns
        // everything after the slash, and comparing the whole address would wipe it on every redraw.
        .onChange(of: section) { if Self.head(of: tab.section) != section.rawValue { tab.section = section.rawValue } }
    }

    /// The address of a pane is one word, or two with a slash between them: `#privacy/sites` is the
    /// third row of the sidebar and the second segment inside it. Only Privacy has a second word
    /// today, and it has one because the shield's menu has two items that used to lead to the same
    /// place — "Site Permissions…" arrived on the filter lists, which is the fault `#assistant` was
    /// added to fix, one level further down.
    private static func head(of address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        return String(address.split(separator: "/", maxSplits: 1)[0])
    }

    private static func tail(of address: String?) -> String? {
        guard let address, let slash = address.firstIndex(of: "/") else { return nil }
        let rest = address[address.index(after: slash)...]
        return rest.isEmpty ? nil : String(rest)
    }

    private static func pane(of address: String?) -> Section? {
        head(of: address).flatMap(Section.init(rawValue:))
    }

    /// The part after the slash, written back under whichever pane is showing.
    private var part: Binding<String?> {
        Binding(
            get: { Self.tail(of: tab.section) },
            set: { tab.section = $0.map { "\(section.rawValue)/\($0)" } ?? section.rawValue }
        )
    }

    private var sidebar: some View {
        List(Section.allCases, selection: $section) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
        }
        .listStyle(.sidebar)
        // A share of the window, like everything else in the layout: a column is a screen wide on a
        // laptop and on a 5K panel, and a 200-point list is a different thing on each.
        .frame(width: sidebarWidth)
    }

    private var sidebarWidth: CGFloat {
        max(180, min(280, Platform.screenSize.width * 0.11))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: section.symbol)
            Text(section.title).font(.headline)
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .general: GeneralConfiguration()
        case .windows: WindowConfiguration()
        case .privacy: PrivacyConfiguration(part: part)
        case .assistant: AssistantPane()
        case .extensions: ExtensionConfiguration()
        case .develop: DevelopConfiguration()
        }
    }
}

// MARK: - General

/// What six searches with, what it does with a page's language, and whether the machine sends it
/// every link.
private struct GeneralConfiguration: View {
    @Environment(ConfigurationStore.self) private var settings
    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        @Bindable var settings = settings
        Form {
            SwiftUI.Section("Search") {
                Picker("Search Engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
            }

            SwiftUI.Section("Translation") {
                Picker("Translate Pages Into", selection: Binding(
                    get: { browser.translationTarget.languageCode?.identifier ?? "en" },
                    set: { browser.translationTarget = Locale.Language(identifier: $0) }
                )) {
                    ForEach(browser.appleTranslator.languages, id: \.maximalIdentifier) { language in
                        Text(AppleTranslator.name(of: language))
                            .tag(language.languageCode?.identifier ?? "")
                    }
                }
                .task { await browser.appleTranslator.loadLanguages() }
            }

            SwiftUI.Section("Bookmarks") {
                Picker("Search In", selection: $settings.bookmarkScope) {
                    ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
                }
                Picker("Re-read Saved Pages", selection: $settings.bookmarkRefreshDays) {
                    Text("Never").tag(0)
                    Text("Daily").tag(1)
                    Text("Weekly").tag(7)
                    Text("Monthly").tag(30)
                }
                // A menu rather than a plain picker, because a picker shows the same text closed as
                // open: the list wants the sizes and the recommendation, the closed button only
                // the name of what was chosen.
                let searchModel = Binding(
                    get: { settings.embeddingModel ?? .recommended },
                    // The setting and the running store move together: the store creates the new
                    // model's table and re-indexes, and the footer of the bookmarks window says how
                    // far it has got.
                    set: { (choice: EmbeddingModelChoice) in
                        settings.embeddingModel = choice
                        bookmarks.use(choice)
                    }
                )
                LabeledContent("Search Model") {
                    Menu(searchModel.wrappedValue.name) {
                        Picker("Search Model", selection: searchModel) {
                            ForEach(EmbeddingModelChoice.allCases) { choice in
                                Text(choice == .recommended ? String(localized: "\(choice.title) — recommended for this Mac") : choice.title)
                                    .tag(choice)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .fixedSize()
                }
                Text("Changing the model re-indexes every saved page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("In This Profile") {
                    HStack(spacing: 8) {
                        Text("\(bookmarks.count(in: browser.selectedProfile.id)) saved")
                            .foregroundStyle(.secondary)
                        Button("Re-read Now") { bookmarks.refreshAll(in: browser.selectedProfile.id) }
                            .controlSize(.small)
                            .disabled(bookmarks.count(in: browser.selectedProfile.id) == 0)
                    }
                }
            }

            SwiftUI.Section("Sharing") {
                ShareExtensionRow()
            }

            // A development build is a second app wearing the same face, and giving it the web
            // would send every link on the machine into a browser that is about to be killed and
            // built again — so it is not offered the choice at all, rather than shown a dead one.
            if !AppSupport.isDevelopment {
                SwiftUI.Section("Default Browser") {
                    LabeledContent("Links From Other Apps") {
                        if DefaultBrowser.isDefault {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Set six as Default Browser…") {
                                Task { await DefaultBrowser.makeDefault() }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The system's switch for six's own share extension, brought here.
///
/// It lives in System Settings, several screens deep; six switches it on once at the first launch
/// that finds it off, and this is where it is turned back off (`ShareExtensionSwitch`). The state is
/// read from the system every time this page appears rather than kept in the database: System
/// Settings can have changed it since, and a switch that shows six's opinion instead of the system's
/// would be a lie the moment it did.
private struct ShareExtensionRow: View {
    @State private var state: ShareExtensionSwitch.State?
    @State private var isWorking = false

    var body: some View {
        Toggle("Show six in the Share Menu", isOn: Binding(
            get: { state == .on },
            set: { on in
                isWorking = true
                Task { state = await ShareExtensionSwitch.set(on); isWorking = false }
            }
        ))
        .disabled(state == nil || state == .unregistered || isWorking)
        .task { state = await ShareExtensionSwitch.state() }
        if state == .unregistered {
            Text("Not registered yet — launch six from where it is installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Windows

/// How the rail behaves — the two switches that used to be in the Layout menu, and are the only two
/// of it that were settings at all.
private struct WindowConfiguration: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Centre the Focused Window", isOn: Binding(
                    get: { browser.layout.centersFocus },
                    set: { _ in browser.toggleCenterFocus() }
                ))
            } header: {
                Text("The Rail")
            }

            SwiftUI.Section {
                Toggle("Show Neighbours When Hovering Beside the Window", isOn: Binding(
                    get: { browser.peeksAtEdges },
                    set: { _ in browser.togglePeeksAtEdges() }
                ))
            }

            SwiftUI.Section("Loaded Windows") {
                LoadedWindows()
            }
        }
        .formStyle(.grouped)
    }
}

/// What the live-page budget is doing, with nothing to set.
///
/// It used to be a picker: seven numbers in the Layout menu, under a status line. How many web
/// content processes a Mac can carry is not a thing a person knows — it is read off the machine's
/// memory at launch and moved again whenever the system reports pressure. So the number is shown,
/// because "why did that window reload" deserves an answer, and it is not asked for.
private struct LoadedWindows: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        LabeledContent("Pages in Memory") {
            Text("\(browser.pages.liveCount) of \(browser.tabs.count)").foregroundStyle(.secondary)
        }
        Button("Unload Background Windows Now") { browser.pages.discardBackgroundPages() }
            .controlSize(.small)
    }
}

// MARK: - Privacy

/// Blocking, what each site was allowed, and what six trusts — the whole of the old Privacy menu,
/// which was a menu whose every item opened a window.
private struct PrivacyConfiguration: View {
    /// This pane's own half of the address, from `ConfigurationPageView`: `sites` of
    /// `#privacy/sites`. Held there rather than here because the address belongs to the window and
    /// outlives this view — the segment is `@State`, and switching panes and back rebuilds it.
    @Binding var part: String?

    @Environment(ContentBlocker.self) private var blocker
    @State private var pane: Pane = .blocking

    private enum Pane: String, CaseIterable, Identifiable {
        case blocking, sites, certificates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blocking: String(localized: "Blocking")
            case .sites: String(localized: "Site Permissions")
            case .certificates: String(localized: "Certificates")
            }
        }
    }

    var body: some View {
        @Bindable var blocker = blocker
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if pane == .blocking {
                    if blocker.isWorking { ProgressView().controlSize(.small) }
                    Toggle("Block Ads and Trackers", isOn: $blocker.isEnabled)
                        .toggleStyle(.switch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch pane {
            case .blocking: BlockingConfiguration()
            case .sites: PermissionConfiguration()
            case .certificates: CertificateConfiguration()
            }
        }
        .onAppear { if let named = part.flatMap(Pane.init(rawValue:)) { pane = named } }
        .onChange(of: part) { if let named = part.flatMap(Pane.init(rawValue:)), named != pane { pane = named } }
        .onChange(of: pane) { if part != pane.rawValue { part = pane.rawValue } }
    }
}

// MARK: - Develop

/// Safari's inspector and six's own log — the two things a person developing against six reads.
private struct DevelopConfiguration: View {
    @Environment(DevToolsStore.self) private var devTools

    var body: some View {
        @Bindable var devTools = devTools
        Form {
            SwiftUI.Section("Web Inspector") {
                // six has no inspector window of its own — WebKit lets an app allow inspection, not
                // open it. Where to attach from is written here rather than left to devtools.md.
                // The computer is named by what it is rather than by what it is called: the name is
                // whatever Sharing says, and read here it looked like something six had made up.
                Toggle("Allow Safari to Inspect six's Pages", isOn: $devTools.isInspectable)
                Text("In Safari: the Develop menu, this computer's name, then \(DevToolsStore.appName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if devTools.isInspectable {
                    Button("Open Safari to Attach") {
                        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                            NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    .controlSize(.small)
                }
            }

            SwiftUI.Section("Log") {
                // The capture above belongs to a window and is gone when it navigates; this is the
                // browser's own account of itself, kept on disk across launches. Naming the path
                // here is most of the point — a log nobody can find is a log nobody reads.
                Text("six writes what it did to \(Log.current.path(percentEncoded: false)), and to the system log under \(Bundle.main.bundleIdentifier ?? "org.deffun.six").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.current])
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
