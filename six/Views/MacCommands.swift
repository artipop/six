#if os(macOS)
import SwiftUI
import WebKit

/// niri's bindings, with ⌥ standing in for Mod.
struct LayoutCommands: Commands {
    let browser: BrowserState

    var body: some Commands {
        CommandMenu("Layout") {
            Button("Focus Column Left") { browser.focusColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Focus Column Right") { browser.focusColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Focus First Column") { browser.focusColumnEdge(last: false) }
                .keyboardShortcut(.home, modifiers: .option)
            Button("Focus Last Column") { browser.focusColumnEdge(last: true) }
                .keyboardShortcut(.end, modifiers: .option)

            Divider()

            Button("Move Column Left") { browser.moveColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Button("Move Column Right") { browser.moveColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])

            Divider()

            Button("Focus Workspace Up") { browser.focusWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Focus Workspace Down") { browser.focusWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Move Column to Workspace Up") { browser.moveColumnToWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Move Column to Workspace Down") { browser.moveColumnToWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])

            Divider()

            Button("Wider Columns") { browser.stepColumnWidth(1) }
                .keyboardShortcut("r", modifiers: .option)
                .disabled(browser.layout.preferredWidthIndex == NiriLayout.widthPresets.count - 1)
            Button("Narrower Columns") { browser.stepColumnWidth(-1) }
                .keyboardShortcut("r", modifiers: [.option, .shift])
                .disabled(browser.layout.preferredWidthIndex == 0)
            Picker("Column Width", selection: Binding(
                get: { browser.layout.preferredWidthIndex },
                set: { browser.setColumnWidth($0) }
            )) {
                ForEach(Array(NiriLayout.widthPresets.enumerated()), id: \.offset) { index, fraction in
                    Text(NiriLayout.widthPresetTitles[index]).tag(index)
                }
            }
            .pickerStyle(.inline)
            Toggle("Compact Width", isOn: Binding(
                get: { browser.layout.focusedColumnIsFullWidth },
                set: { _ in browser.toggleCompactWidth() }
            ))
            .keyboardShortcut("f", modifiers: .option)
            Toggle("Full Window", isOn: Binding(
                get: { browser.layout.fill == .window },
                set: { _ in browser.toggleFullWindow() }
            ))
            .keyboardShortcut("w", modifiers: .option)
            Toggle("Fullscreen", isOn: Binding(
                get: { browser.layout.fill == .screen },
                set: { _ in browser.toggleFullscreen() }
            ))
            .keyboardShortcut("f", modifiers: [.option, .shift])
            Button("Toggle Overview") { browser.toggleOverview() }
                .keyboardShortcut("o", modifiers: .option)

            Divider()

            Toggle("Center Focused Window", isOn: Binding(
                get: { browser.layout.centersFocus },
                set: { _ in browser.toggleCenterFocus() }
            ))
            .keyboardShortcut("c", modifiers: .option)

            Divider()

            // Windows off the screen give their pages back when the app runs over this (see
            // `LivePageCache`); they keep everything it takes to put the same page back when they
            // come round again. The default is sized from the machine's memory.
            Section("Loaded Windows: \(browser.pages.liveCount) of \(browser.tabs.count)") {
                Picker("Keep Loaded", selection: Binding(
                    get: { browser.pages.budget },
                    set: { browser.setLivePageBudget($0) }
                )) {
                    ForEach([4, 6, 8, 12, 16, 24, 40], id: \.self) { count in
                        Text("\(count) windows").tag(count)
                    }
                }
                .pickerStyle(.inline)
                Button("Unload Background Windows") { browser.pages.discardBackgroundPages() }
            }
        }
    }
}

/// The selected profile's recent pages, and ⌘Y for the whole thing.
struct HistoryCommands: Commands {
    let browser: BrowserState
    @FocusedValue(\.showHistory) private var showHistory
    @FocusedValue(\.clearHistory) private var clearHistory

    var body: some Commands {
        CommandMenu("History") {
            Button("Show History…") { showHistory?.perform() }
                .keyboardShortcut("y")
                .disabled(showHistory == nil)
            Divider()
            let profile = browser.selectedProfile
            Section(profile.name) {
                let recent = browser.history.recent(in: profile.id, limit: 20)
                if recent.isEmpty {
                    Text("No History").disabled(true)
                }
                ForEach(recent) { entry in
                    Button(SearchEngine.search(from: entry.url).map { String(localized: "\($0.query) — \($0.engine.title) Search") } ?? entry.displayTitle) {
                        browser.newTab(url: entry.url, in: entry.profileID)
                    }
                }
            }
            Divider()
            Button("Clear \(profile.name) History…") { clearHistory?.perform() }
                .disabled(clearHistory == nil)
        }
    }
}

/// ⌘D saves the page; the menu lists the profile's recent bookmarks and sets what the assistant searches.
struct BookmarkCommands: Commands {
    let browser: BrowserState
    let bookmarks: BookmarkStore
    let settings: SettingsStore
    @FocusedValue(\.showBookmarks) private var showBookmarks

    var body: some Commands {
        CommandMenu("Bookmarks") {
            let tab = browser.selectedTab
            let saved = tab.map { bookmarks.isBookmarked($0) } ?? false
            Button(saved ? "Remove Bookmark" : "Add Bookmark") {
                guard let tab else { return }
                if saved, let url = tab.currentURL, let existing = bookmarks.bookmark(for: url, in: tab.profileID) {
                    bookmarks.remove(existing.id)
                } else {
                    Task { try? await bookmarks.add(tab) }
                }
            }
            .keyboardShortcut("d")
            .disabled(tab == nil || tab?.showsStartPage == true || tab.map { browser.isPrivate($0.profileID) } == true)
            Button("Show Bookmarks…") { showBookmarks?.perform() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(showBookmarks == nil)
            Divider()
            @Bindable var settings = settings
            Picker("Assistant Searches", selection: $settings.bookmarkScope) {
                ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            let profile = browser.selectedProfile
            let current = tab.flatMap { tab in tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) } }
            Button("Refresh Bookmark") { if let current { Task { await bookmarks.refresh(current.id) } } }
                .disabled(current == nil)
            Button("Refresh \(profile.name) Bookmarks") { bookmarks.refreshAll(in: profile.id) }
                .disabled(bookmarks.count(in: profile.id) == 0)
            Picker("Re-read Saved Pages", selection: $settings.bookmarkRefreshDays) {
                Text("Never").tag(0)
                Text("Daily").tag(1)
                Text("Weekly").tag(7)
                Text("Monthly").tag(30)
            }
            Divider()
            Section(profile.name) {
                let recent = bookmarks.entries(in: .profile, profileID: profile.id).prefix(15)
                if recent.isEmpty {
                    Text("No Bookmarks").disabled(true)
                }
                ForEach(Array(recent)) { entry in
                    Button(entry.displayTitle) { browser.newTab(url: entry.url, in: entry.profileID) }
                }
            }
        }
    }
}

/// Blocking, and the two things a person actually does with it: let this site through, and look at
/// the lists.
struct PrivacyCommands: Commands {
    let browser: BrowserState
    let blocker: ContentBlocker
    @FocusedValue(\.showFilterLists) private var showFilterLists
    @FocusedValue(\.showSitePermissions) private var showSitePermissions

    var body: some Commands {
        CommandMenu("Privacy") {
            @Bindable var blocker = blocker
            Toggle("Block Ads and Trackers", isOn: $blocker.isEnabled)
            let tab = browser.selectedTab
            let url = tab?.currentURL
            let host = url?.host() ?? ""
            let allowed = url.map { blocker.allows($0) && blocker.isEnabled } ?? false
            Button(allowed ? "Block Ads on \(host)" : "Allow Ads on \(host)") {
                guard let tab else { return }
                browser.setBlockingAllowed(!allowed, for: tab)
            }
            .disabled(!blocker.isEnabled || url == nil || host.isEmpty)
            Divider()
            Button("Update Filter Lists Now") { Task { await blocker.updateNow() } }
                .disabled(!blocker.isEnabled || blocker.isWorking)
            Button("Filter Lists…") { showFilterLists?.perform() }
                .disabled(showFilterLists == nil)
            Divider()
            Button("Site Permissions…") { showSitePermissions?.perform() }
                .disabled(showSitePermissions == nil)
        }
    }
}

/// Extensions: the panel, and each extension's own action for the focused window.
struct ExtensionCommands: Commands {
    let browser: BrowserState
    let extensions: ExtensionStore
    @FocusedValue(\.showExtensions) private var showExtensions

    var body: some Commands {
        CommandMenu("Extensions") {
            Button("Manage Extensions…") { showExtensions?.perform() }
                .disabled(showExtensions == nil)
            Divider()
            let tab = browser.selectedTab
            let actions = tab.map { extensions.actions(for: $0) } ?? []
            if actions.isEmpty {
                Text(extensions.installed.isEmpty ? "None installed" : "Nothing for this window")
            } else {
                ForEach(actions, id: \.record.id) { pair in
                    Button(pair.action.label ?? pair.record.name) {
                        guard let tab else { return }
                        extensions.performAction(pair.record, for: tab, anchor: nil)
                    }
                    .disabled(!pair.action.isEnabled)
                }
            }
        }
    }
}

/// The MCP apps six can open — a server, a tool of it that carries an interface, a window.
///
/// The list is the servers on `six://apps`, which is also where they are added; picking one here
/// runs its first app tool. See [mcp-apps.md](../../docs/mcp-apps.md).
struct AppCommands: Commands {
    let browser: BrowserState
    let apps: MCPAppStore

    var body: some Commands {
        CommandMenu("Apps") {
            Button("Manage Servers…") { browser.openBuiltIn(.apps) }
            Divider()
            if apps.servers.isEmpty {
                Text("No servers yet")
            }
            ForEach(apps.servers) { server in
                Button(server.name) {
                    Task { try? await apps.open(server) }
                }
            }
            Divider()
            // The second half of the menu is not about opening a window: it is about whether the
            // agent is handed this server's tools at all, and so whether it can open one itself.
            Menu("Give to the Agent") {
                ForEach(apps.servers) { server in
                    Toggle(server.name, isOn: Binding(
                        get: { apps.isShared(server) },
                        set: { apps.setShared(server, $0) }))
                }
            }
            .help("Shared servers' tools reach the agent as six's own; a tool with an interface opens a window")
            if let error = apps.lastError {
                Divider()
                Text(error)
            }
        }
    }
}

/// Developer tools: Safari's inspector on six's pages, and the capture the agent tools read.
struct DevelopCommands: Commands {
    let devTools: DevToolsStore

    var body: some Commands {
        CommandMenu("Develop") {
            @Bindable var devTools = devTools
            // six has no inspector window of its own — WebKit lets an app allow inspection, not open
            // it. Where to attach from is in the help tag and in devtools.md, not in the menu.
            Toggle("Web Inspector", isOn: $devTools.isInspectable)
                .help("Then attach from Safari: Develop › \(DevToolsStore.machineName) › six")
            if devTools.isInspectable {
                Button("Open Safari to Attach") {
                    if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                        NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
            Toggle("Capture Console and Network", isOn: $devTools.isCapturing)
                .help("For list_console_messages and list_network_requests; runs a hook in the page's own world")
            Divider()
            Button("Clear Captured Logs") { devTools.clear() }
                .disabled(!devTools.isCapturing)
        }
    }
}

struct BrowserCommands: Commands {
    let settings: SettingsStore
    @FocusedValue(\.focusAddressBar) private var focusAddressBar
    @FocusedValue(\.focusAssistant) private var focusAssistant
    @FocusedValue(\.toggleAgentPanel) private var toggleAgentPanel
    @FocusedValue(\.translatePage) private var translatePage
    @FocusedValue(\.translateSelection) private var translateSelection

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location…") { focusAddressBar?.perform() }
                .keyboardShortcut("l")
                .disabled(focusAddressBar == nil)
            Button("Ask Assistant…") { focusAssistant?.perform() }
                .keyboardShortcut("k")
                .disabled(focusAssistant == nil)
            Button("Toggle Agent Panel") { toggleAgentPanel?.perform() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(toggleAgentPanel == nil)

            Divider()

            // ⌘⇧L: "L" for language, next to ⌘L in the hand. Deliberately not ⌘⇧T, which is free
            // today but is "reopen closed tab" in every other browser.
            Button("Translate Page") { translatePage?.perform() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(translatePage == nil)
            // ⌥⇧T beside ⌥⇧H "Highlight Selection": the same shape of gesture on the same thing.
            // Always enabled, because nothing here can know whether there is a selection without
            // asking the page, and a menu cannot await — pressing it with none says so.
            Button("Translate Selection…") { translateSelection?.perform() }
                .keyboardShortcut("t", modifiers: [.option, .shift])
                .disabled(translateSelection == nil)

            Divider()

            @Bindable var settings = settings
            Picker("Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
        }
    }
}
#endif
