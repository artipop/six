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
struct SettingsPageView: View {
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
        case .general: GeneralSettings()
        case .windows: WindowSettings()
        case .privacy: PrivacySettings()
        case .assistant: AssistantPane()
        case .extensions: ExtensionSettings()
        case .develop: DevelopSettings()
        }
    }
}

// MARK: - General

/// What six searches with, what it does with a page's language, and whether the machine sends it
/// every link.
private struct GeneralSettings: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        @Bindable var settings = settings
        Form {
            SwiftUI.Section("Search") {
                Picker("Search Engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
                Text("Used for what is typed in the address field and for the suggestions under it. Also on the start page, as the chip beside the field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Picker("The Assistant Searches", selection: $settings.bookmarkScope) {
                    ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
                }
                Picker("Re-read Saved Pages", selection: $settings.bookmarkRefreshDays) {
                    Text("Never").tag(0)
                    Text("Daily").tag(1)
                    Text("Weekly").tag(7)
                    Text("Monthly").tag(30)
                }
                Picker("Model for Search by Meaning", selection: Binding(
                    get: { settings.embeddingModel ?? .recommended },
                    // The setting and the running store move together: the store creates the new
                    // model's table and re-indexes, and the footer of the bookmarks window says how
                    // far it has got.
                    set: { choice in
                        settings.embeddingModel = choice
                        bookmarks.use(choice)
                    }
                )) {
                    ForEach(EmbeddingModelChoice.allCases) { choice in
                        Text(choice == .recommended ? String(localized: "\(choice.title) — recommended for this Mac") : choice.title)
                            .tag(choice)
                    }
                }
                Text("Recommended by this Mac's memory. The other one is yours to choose, at your own risk: the larger model ranks a little better between languages, downloads about twice as much and holds twice as much memory while six runs — on a Mac with less than 16 GB that is paid for by the pages. Either way, changing this embeds every saved page again.")
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

            // A development build is a second app wearing the same face, and giving it the web
            // would send every link on the machine into a browser that is about to be killed and
            // built again — so it is not offered the choice at all, rather than shown a dead one.
            if !AppSupport.isDevelopment {
                SwiftUI.Section("Default Browser") {
                    LabeledContent("Links From Other Apps") {
                        if DefaultBrowser.isDefault {
                            Label("six opens them", systemImage: "checkmark.circle")
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

// MARK: - Windows

/// How the rail behaves — the two switches that used to be in the Layout menu, and are the only two
/// of it that were settings at all.
private struct WindowSettings: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Centre the Focused Window", isOn: Binding(
                    get: { browser.layout.centersFocus },
                    set: { _ in browser.toggleCenterFocus() }
                ))
                Text("On, the window you are reading sits in the middle of the screen and both neighbours peek in by the same amount. Off, the rail moves as little as it can — ⌥C.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("The Rail")
            }

            SwiftUI.Section {
                Toggle("Peek at the Edges", isOn: Binding(
                    get: { browser.peeksAtEdges },
                    set: { _ in browser.togglePeeksAtEdges() }
                ))
                Text("On, nothing is drawn in the gaps beside the focused window until the pointer arrives, and the rail leans over to show what is on that side. Off, the buttons stand where they are and do their job on the way in — which is the only thing that works without a pointer to rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        LabeledContent("Holding a Page") {
            Text("\(browser.pages.liveCount) of \(browser.tabs.count)").foregroundStyle(.secondary)
        }
        Text("A window off the screen gives its page back when six is over what this machine can carry, and keeps everything it takes to put the same page back — its address, its history, its scroll offset and a picture of itself. The budget comes from the machine's memory and follows the pressure the system reports.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Unload Background Windows Now") { browser.pages.discardBackgroundPages() }
            .controlSize(.small)
    }
}

// MARK: - Privacy

/// Blocking, what each site was allowed, and what six trusts — the whole of the old Privacy menu,
/// which was a menu whose every item opened a window.
private struct PrivacySettings: View {
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
                        .help("Off means off: nothing is fetched, compiled or attached to a page")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch pane {
            case .blocking: BlockingSettings()
            case .sites: PermissionSettings()
            case .certificates: CertificateSettings()
            }
        }
    }
}

// MARK: - Assistant

/// Which model answers ⌘K, which agent answers the panel, and who each of them is told to call.
/// Named a pane rather than `AssistantSettings`, which is the model object it edits.
private struct AssistantPane: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(ResearchCoordinator.self) private var research
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var settings = assistant.settings
        @Bindable var agentSession = agentSession
        @Bindable var research = research
        @Bindable var store = store
        Form {
            // The switch over the whole pane, and over more than the pane: with it off nothing
            // below is built at all (`SettingsStore.isAIEnabled`), which is why the rest goes grey
            // rather than disappearing — a settings page that empties itself is a settings page you
            // cannot find your way back through.
            SwiftUI.Section {
                Toggle("Use Language Models and Agents", isOn: $store.isAIEnabled)
                Text("The ⌘K line, the verbs over selected text and in a field, the agent panel, deep research, and six's own MCP server. Off means none of them run and nothing is added to a page. Bookmark search and page translation are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Group {
                SwiftUI.Section("Model") {
                    Picker("The ⌘K Line Asks", selection: $settings.model) {
                        ForEach(ModelChoice.languageModels) { choice in
                            Label(choice.title, systemImage: choice.symbol)
                                .tag(choice)
                                .disabled(choice.isThirdParty && !FoundationModelsCompatibility.supportsThirdPartyModels)
                        }
                        ForEach(ModelChoice.agents) { choice in
                            Label(choice.title, systemImage: choice.symbol).tag(choice)
                        }
                    }
                    if !FoundationModelsCompatibility.supportsThirdPartyModels {
                        Text("Remote models unavailable: SDK/OS Foundation Models mismatch")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                SwiftUI.Section("Agent Panel") {
                    TextField("Model", text: $agentSession.modelOverride, prompt: Text("the agent's own default"))
                    Text("Passed to the ACP agent as ANTHROPIC_MODEL. Blank leaves the agent on whatever it picks for itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SwiftUI.Section("Deep Research") {
                    Stepper("Sources: \(research.sourceCount)", value: $research.sourceCount, in: 1...20)
                }

                AssistantProviderSettings()
            }
            // Everything below the switch is about a thing that is not running while it is off.
            // Greyed out rather than gone: a pane that empties itself gives you nothing to read
            // when you are deciding whether to switch it back on.
            .disabled(!store.isAIEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Develop

/// The two switches the Develop menu carried, and the two things it could do.
private struct DevelopSettings: View {
    @Environment(DevToolsStore.self) private var devTools

    var body: some View {
        @Bindable var devTools = devTools
        Form {
            SwiftUI.Section("Web Inspector") {
                // six has no inspector window of its own — WebKit lets an app allow inspection, not
                // open it. Where to attach from is written here rather than left to devtools.md.
                Toggle("Allow Safari to Inspect six's Pages", isOn: $devTools.isInspectable)
                Text("Then attach from Safari: Develop › \(DevToolsStore.machineName) › six")
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

            SwiftUI.Section("Capture") {
                Toggle("Capture Console and Network", isOn: $devTools.isCapturing)
                Text("For the list_console_messages and list_network_requests tools; it runs a hook in the page's own world.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Captured Logs") { devTools.clear() }
                    .controlSize(.small)
                    .disabled(!devTools.isCapturing)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
