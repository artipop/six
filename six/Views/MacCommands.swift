#if os(macOS)
import SwiftUI
import WebKit

/// What six's menu bar is left with, and why.
///
/// It used to carry thirteen menus. Five of them — Layout, Navigate, Privacy, Extensions, Develop —
/// were one feature each, and most of what was in them was a switch that stayed where it was put.
/// A switch is not a command: it has no key, it does not answer "what can I do here", and a person
/// hunting for one has no way to guess which of five menus it filed itself under. Those went to
/// `six://settings` (⌘,).
///
/// What is left is the shape every browser has — File, Edit, View, History, Bookmarks — plus Apps,
/// which is six's own and is a list of things to *open*. The rule for anything new: a menu item is
/// a verb with a key beside it; everything else is a setting.

/// The window in front, and how the rail is showing it.
///
/// The ⌥ bindings that walk the rail are deliberately *not* here — they live in `KeyBindings`, which
/// `KeyRouter` walks on a key monitor that sees a key before the focused web view does. A menu item
/// cannot: WebKit takes `⌥←` and `⌥→` for word movement and the layout key never arrives. The `⌥`
/// items that *are* here are here for display and for the pointer — the router answers the key first
/// and swallows it, so the item's own action never runs.
struct ViewCommands: Commands {
    let browser: BrowserState
    @FocusedValue(\.focusAssistant) private var focusAssistant
    @FocusedValue(\.toggleAgentPanel) private var toggleAgentPanel
    @FocusedValue(\.translatePage) private var translatePage
    @FocusedValue(\.translateSelection) private var translateSelection

    var body: some Commands {
        CommandMenu("View") {
            // The verbs the deleted Navigate menu took with it. Reload is the key a browser is
            // pressed most often by, and six had none — the button in the address bar was the whole
            // of it. They are `⌘`, so they are menu items and not `KeyBindings` rows, and measuring
            // says that is enough: posted into a window whose focused `WKWebView` is first
            // responder, `⌘R` reloads and `⌘[` walks back (`KeySelfTest.menuKeys`). WebKit takes
            // `⌥←` and does not take these.
            //
            // **Nothing here greys out, and that is not laziness.** `.disabled` is decided when this
            // body is built, and what it would be decided on — `canGoBack`, `isLoading` — changes
            // with every navigation without rebuilding it. An item left disabled by a stale answer
            // does not answer its key equivalent either, and the first version of this menu was dead
            // for exactly that reason: `⌘[` did nothing until the modifier came off, with a
            // single-variable run each way to prove it was the modifier and not the action. So the
            // window is read *inside* the action, where it is always the one in front, and a key
            // pressed where it has nothing to do does nothing — the same bargain Picture in Picture
            // states below, arrived at the same way.
            Button("Reload") { browser.selectedTab?.reload() }
                .keyboardShortcut("r")
            Button("Reload From Origin") { browser.selectedTab?.reloadFromOrigin() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Stop") { browser.selectedTab?.stop() }
                .keyboardShortcut(".")

            Divider()

            Toggle("Full Width", isOn: Binding(
                get: { browser.layout.fill == .window },
                set: { _ in browser.toggleFullWindow() }
            ))
            .keyboardShortcut("w", modifiers: .option)
            Toggle("Overview", isOn: Binding(
                get: { browser.layout.isOverview },
                set: { _ in browser.toggleOverview() }
            ))
            .keyboardShortcut("o", modifiers: .option)

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
            // ⌥⇧P joins ⌥⇧T and ⌥⇧H: a verb about the page in front of you, and like them a key the
            // router takes before the focused page can (`KeyBindings`) — which here is the whole
            // point, because the page that has the focus is the one playing the video.
            //
            // Never greyed out. Whether there is a video to float is a question only the page can
            // answer, and the answer changes with every play and pause without telling anyone; a
            // menu that greys itself out on a stale answer is worse than one that does nothing when
            // pressed on a page of text.
            Button("Picture in Picture") { browser.togglePictureInPicture() }
                .keyboardShortcut("p", modifiers: [.option, .shift])

            Divider()

            Button("Ask Assistant…") { focusAssistant?.perform() }
                .keyboardShortcut("k")
                .disabled(focusAssistant == nil)
            Button("Agent Panel") { toggleAgentPanel?.perform() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(toggleAgentPanel == nil)
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
            // Where Safari keeps them, and for the same reason: walking back and forward is walking
            // this window's own history, not the profile's. Never greyed out, and read inside the
            // action — see the note in `ViewCommands`, which is where that was measured.
            Button("Back") { browser.selectedTab?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { browser.selectedTab?.goForward() }
                .keyboardShortcut("]")

            Divider()

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

/// ⌘D saves the page; the menu lists the profile's recent bookmarks.
///
/// What the assistant searches and how often a saved page is re-read were pickers here. They are
/// settings — nobody changes them twice — and they are on `six://settings` under General.
struct BookmarkCommands: Commands {
    let browser: BrowserState
    let bookmarks: BookmarkStore
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
            let current = tab.flatMap { tab in tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) } }
            Button("Refresh Bookmark") { if let current { Task { await bookmarks.refresh(current.id) } } }
                .disabled(current == nil)
            Divider()
            let profile = browser.selectedProfile
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
#endif
