import Foundation
import FoundationModels
import WebKit

/// One browser tool, described once and exposed twice: to the ⌘K assistant as a Foundation Models
/// `Tool` (`BrowserModelTool`) and to ACP agents through MCP (`MCPServer`).
struct BrowserTool {
    enum ParameterType: String { case string, integer, boolean }

    struct Parameter {
        var name: String
        var description: String
        var type: ParameterType = .string
        var required = false
    }

    /// Where the tool is offered. `summarize_page` runs a model of its own, so the assistant — a model
    /// already — doesn't get it.
    struct Surface: OptionSet {
        let rawValue: Int
        static let assistant = Surface(rawValue: 1)
        static let mcp = Surface(rawValue: 2)
        static let all: Surface = [.assistant, .mcp]
    }

    var name: String
    var description: String
    var parameters: [Parameter] = []
    var surfaces: Surface = .all
    var run: (ACPJSON) async throws -> String

    /// Caller-facing failure: a bad window id, a missing model. Returned as a tool error, not a crash.
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

/// The tools, speaking the product's language — windows in workspaces in a profile's strip — over the
/// live `BrowserState`. Everything defaults to what is on screen.
@MainActor
final class BrowserToolCatalog {
    private let browser: BrowserState
    private let assistant: AssistantSettings
    private let bookmarks: BookmarkStore
    private let settings: SettingsStore

    init(browser: BrowserState, assistant: AssistantSettings, bookmarks: BookmarkStore, settings: SettingsStore) {
        self.browser = browser
        self.assistant = assistant
        self.bookmarks = bookmarks
        self.settings = settings
    }

    static let instructions = """
        six is a macOS browser with a niri-style layout. There are no tabs: a page is a *window*, windows sit \
        left to right in a *workspace* (a scrollable strip), workspaces are stacked vertically inside a \
        *profile* (an isolated cookie jar such as "Personal" or "Work"). Exactly one workspace of one profile \
        is on screen; its focused window is what the user is looking at. Tools default to that window, \
        workspace and profile. Window ids come from `list_workspaces`. Workspaces are addressed by name or \
        1-based position; naming one that doesn't exist creates it.

        A strip is meant to be filled. When the user asks you to find, compare or shop for something,         search first (`web_search`), then open the several pages actually worth putting side by side —         different sites, or the same site on the different options — each in its own window, each on the         exact page for what was asked (a route, a product, a date), not a site's front page. Reading a         page yourself (`get_page_content`) is for the answer you write; the windows are what the user is         left with.

        The user also keeps *bookmarks*: pages saved as readable Markdown files (outside your working directory) and \
        indexed by meaning. `search_bookmarks` finds them by topic (any language), `list_bookmarks` lists them, \
        `read_bookmark` returns the saved text, `add_bookmark` saves a window's page. Bookmarks belong to a \
        profile; the user chooses in the Bookmarks menu whether the assistant sees this profile's or every \
        profile's, and a `profile` argument (a name, or `all`) overrides that. When a question is about \
        something the user read or saved, search the bookmarks before searching the web — `search_bookmarks` is the \
        way in, then `read_bookmark`; don't grep or read the `Bookmarks/*.md` files (or the original page) \
        yourself, the tools return the same text with the search already done.
        """

    func tools(for surface: BrowserTool.Surface) -> [BrowserTool] {
        all.filter { $0.surfaces.contains(surface) }
    }

    func tool(named name: String) -> BrowserTool? {
        all.first { $0.name == name }
    }

    /// Off-screen, shared by every `web_search` call.
    private lazy var search = WebSearch()

    private static let bookmarkProfile = BrowserTool.Parameter(
        name: "profile", description: "Profile name, or `all`. Default: the scope the user chose in the Bookmarks menu.")

    private static let windowID = BrowserTool.Parameter(
        name: "window_id", description: "Window id from list_workspaces (a prefix is enough). Default: the focused window.")

    private lazy var all: [BrowserTool] = [
        BrowserTool(
            name: "list_workspaces",
            description: "Every profile with its workspaces and the windows (id, title, URL) in each; marks what is focused and on screen.",
            run: { [unowned self] _ in try self.listWorkspaces() }
        ),
        BrowserTool(
            name: "web_search",
            description: "Searches the web and returns ranked results — title, URL and snippet — without opening or "
                + "changing anything. The way to find pages worth opening with `open_window`.",
            parameters: [
                .init(name: "query", description: "What to search for.", required: true),
                .init(name: "count", description: "How many results to return (default 8, at most 25).", type: .integer),
            ],
            run: { [unowned self] args in try await self.webSearch(args) }
        ),
        BrowserTool(
            name: "open_window",
            description: "Opens a new window with a URL, or a web search for `query`. Goes into the on-screen workspace of the "
                + "current profile unless `workspace` (name or 1-based index; a new name creates the workspace) and/or "
                + "`profile` (name) say otherwise. Returns the new window id.",
            parameters: [
                .init(name: "url", description: "Address to load. Scheme-less hosts get https://."),
                .init(name: "query", description: "Search query, used when `url` is absent."),
                .init(name: "workspace", description: "Workspace name or 1-based index. Default: the on-screen workspace."),
                .init(name: "profile", description: "Profile name. Default: the current profile."),
                .init(name: "activate", description: "Focus the new window (default true). false adds it in the background.", type: .boolean),
            ],
            run: { [unowned self] args in try self.openWindow(args) }
        ),
        BrowserTool(
            name: "navigate",
            description: "Loads a URL (or a search query) in an existing window and waits for the page to finish loading.",
            parameters: [Self.windowID, .init(name: "url", description: "Address or search text.", required: true)],
            run: { [unowned self] args in try await self.navigate(args) }
        ),
        BrowserTool(
            name: "get_page_content",
            description: "The visible text of a window's page (waits for loading to finish), with title and URL. Defaults to the focused window.",
            parameters: [Self.windowID, .init(name: "max_chars", description: "Truncate the text to this many characters (default 20000).", type: .integer)],
            run: { [unowned self] args in try await self.pageContent(args) }
        ),
        BrowserTool(
            name: "get_page_links",
            description: "Links on a window's page as `text — URL` lines, in document order. Defaults to the focused window.",
            parameters: [Self.windowID, .init(name: "max_links", description: "At most this many links (default 200).", type: .integer)],
            run: { [unowned self] args in try await self.pageLinks(args) }
        ),
        BrowserTool(
            name: "summarize_page",
            description: "Summarizes a window's page with the browser's own assistant model (the one chosen in ⌘K: on-device, "
                + "Private Cloud Compute or Claude). `focus` narrows the summary to a question or aspect.",
            parameters: [Self.windowID, .init(name: "focus", description: "What the summary should concentrate on, if anything.")],
            surfaces: .mcp,
            run: { [unowned self] args in try await self.summarize(args) }
        ),
        BrowserTool(
            name: "focus_window",
            description: "Brings a window on screen: switches to its profile and workspace and scrolls the strip to it.",
            parameters: [.init(name: "window_id", description: "Window id from list_workspaces (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                self.browser.selectTab(tab.id)
                return "Focused \(Self.describe(tab))"
            }
        ),
        BrowserTool(
            name: "move_window",
            description: "Moves a window to another workspace of its profile (name or 1-based index; a new name creates the workspace).",
            parameters: [
                .init(name: "window_id", description: "Window id from list_workspaces (a prefix is enough).", required: true),
                .init(name: "workspace", description: "Workspace name or 1-based index.", required: true),
            ],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                let index = try self.workspaceIndex(args["workspace"], in: tab.profileID)
                self.browser.moveTab(tab.id, toWorkspace: index)
                return "Moved \(Self.describe(tab)) to \(self.workspaceTitle(index, in: tab.profileID))"
            }
        ),
        BrowserTool(
            name: "close_window",
            description: "Closes a window.",
            parameters: [.init(name: "window_id", description: "Window id from list_workspaces (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                let description = Self.describe(tab)
                self.browser.closeTab(tab.id)
                return "Closed \(description)"
            }
        ),
        BrowserTool(
            name: "list_bookmarks",
            description: "The user's bookmarks, newest first: id, title, URL, site and when it was saved. Scope: the "
                + "profile named in `profile`, `all` profiles, or the user's chosen scope by default.",
            parameters: [Self.bookmarkProfile, .init(name: "limit", description: "At most this many (default 50).", type: .integer)],
            run: { [unowned self] args in try self.listBookmarks(args) }
        ),
        BrowserTool(
            name: "search_bookmarks",
            description: "Semantic search over the saved pages (vectors over the text, plus title/URL matches): the best "
                + "bookmarks for a topic or question, each with the matching passage. Same scope rules as list_bookmarks.",
            parameters: [
                .init(name: "query", description: "What to look for — a topic, a question, a phrase.", required: true),
                Self.bookmarkProfile,
                .init(name: "count", description: "How many results (default 8, at most 30).", type: .integer),
            ],
            run: { [unowned self] args in try await self.searchBookmarks(args) }
        ),
        BrowserTool(
            name: "read_bookmark",
            description: "The saved text of a bookmark as Markdown (with its front matter: title, URL, site, saved date).",
            parameters: [
                .init(name: "bookmark_id", description: "Bookmark id from list_bookmarks / search_bookmarks (a prefix is enough).", required: true),
                .init(name: "max_chars", description: "Truncate to this many characters (default 30000).", type: .integer),
            ],
            run: { [unowned self] args in
                let bookmark = try self.bookmarks.bookmark(matching: args["bookmark_id"]?.stringValue ?? "")
                guard let content = self.bookmarks.content(of: bookmark) else {
                    throw BrowserTool.Failure(message: "The file of \(bookmark.displayTitle) is missing; bookmark the page again")
                }
                let limit = max(500, args["max_chars"]?.intValue ?? 30_000)
                return content.count > limit ? String(content.prefix(limit)) + "\n…[truncated, \(content.count) characters in total]" : content
            }
        ),
        BrowserTool(
            name: "add_bookmark",
            description: "Saves a window's page as a bookmark of its profile: a readable Markdown copy on disk, indexed "
                + "for search. Defaults to the focused window.",
            parameters: [Self.windowID],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                do {
                    let bookmark = try await self.bookmarks.add(tab)
                    return "Bookmarked \(Self.describe(tab)) as \(bookmark.id.uuidString) (\(bookmark.characterCount) characters saved)"
                } catch {
                    throw BrowserTool.Failure(message: error.localizedDescription)
                }
            }
        ),
        BrowserTool(
            name: "remove_bookmark",
            description: "Deletes a bookmark and its saved file.",
            parameters: [.init(name: "bookmark_id", description: "Bookmark id (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let bookmark = try self.bookmarks.bookmark(matching: args["bookmark_id"]?.stringValue ?? "")
                self.bookmarks.remove(bookmark.id)
                return "Removed bookmark \(bookmark.displayTitle) <\(bookmark.url.absoluteString)>"
            }
        ),
        BrowserTool(
            name: "evaluate_javascript",
            description: "Runs JavaScript in a window's page (as a function body; `return` a value to get it back as JSON). "
                + "Defaults to the focused window.",
            parameters: [Self.windowID, .init(name: "script", description: "JavaScript function body.", required: true)],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                guard let script = args["script"]?.stringValue else { throw BrowserTool.Failure(message: "script is required") }
                let value = try await tab.page.callJavaScript(script)
                return Self.describeJavaScriptValue(value)
            }
        ),
    ]

    // MARK: Lookups

    /// A tool looking at a window counts as showing it: a restored one starts loading here.
    private func tab(_ args: ACPJSON) throws -> BrowserTab {
        guard let raw = args["window_id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            guard let tab = browser.selectedTab else { throw BrowserTool.Failure(message: "No focused window") }
            tab.resumeIfNeeded()
            return tab
        }
        let matches = browser.tabs.filter { $0.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }
        guard let tab = matches.first else { throw BrowserTool.Failure(message: "No window with id \(raw); call list_workspaces") }
        guard matches.count == 1 else { throw BrowserTool.Failure(message: "Window id \(raw) is ambiguous") }
        tab.resumeIfNeeded()
        return tab
    }

    private func profile(_ value: ACPJSON?) throws -> Profile {
        guard let name = value?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return browser.selectedProfile
        }
        guard let profile = browser.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw BrowserTool.Failure(message: "No profile named \(name). Profiles: \(browser.profiles.map(\.name).joined(separator: ", "))")
        }
        return profile
    }

    /// A name (created when missing) or a 1-based position; nil means the strip's focused workspace.
    private func workspaceIndex(_ value: ACPJSON?, in profileID: Profile.ID) throws -> Int {
        let strip = browser.layout.strip(for: profileID)
        guard let value, !value.isNull else { return strip.focus }
        if let number = value.intValue ?? value.stringValue.flatMap({ Int($0) }) {
            guard number >= 1, number <= strip.workspaces.count else {
                throw BrowserTool.Failure(message: "Workspace \(number) doesn't exist; this profile has \(strip.workspaces.count)")
            }
            return number - 1
        }
        guard let name = value.stringValue,
              let index = browser.layout.workspaceIndex(named: name, in: profileID, createIfMissing: true) else {
            throw BrowserTool.Failure(message: "workspace must be a name or a 1-based index")
        }
        return index
    }

    private func workspaceTitle(_ index: Int, in profileID: Profile.ID) -> String {
        let name = browser.layout.strip(for: profileID).workspaces[index].name
        return name.isEmpty ? "workspace \(index + 1)" : name
    }

    /// The bookmark scope a tool works in: an explicit profile, `all`, or the user's setting.
    private func bookmarkScope(_ value: ACPJSON?) throws -> (scope: BookmarkScope, profileID: Profile.ID) {
        if let name = value?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if name.caseInsensitiveCompare("all") == .orderedSame { return (.all, browser.selectedProfileID) }
            return (.profile, try profile(value).id)
        }
        return (settings.bookmarkScope, browser.selectedProfileID)
    }

    private func describeScope(_ scope: (scope: BookmarkScope, profileID: Profile.ID)) -> String {
        scope.scope == .all ? "all profiles" : (browser.profiles.first { $0.id == scope.profileID }?.name ?? "profile")
    }

    private static func describe(_ bookmark: Bookmark) -> String {
        let profileTag = bookmark.profileID.uuidString
        let date = bookmark.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "\(bookmark.displayTitle) <\(bookmark.url.absoluteString)> — \(bookmark.displayDetail), saved \(date) [\(bookmark.id.uuidString)] profile:\(profileTag.prefix(8))"
    }

    private func listBookmarks(_ args: ACPJSON) throws -> String {
        let scope = try bookmarkScope(args["profile"])
        let limit = max(1, args["limit"]?.intValue ?? 50)
        let entries = bookmarks.entries(in: scope.scope, profileID: scope.profileID)
        guard !entries.isEmpty else { return "No bookmarks in \(describeScope(scope))." }
        let profileNames = Dictionary(browser.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let lines = entries.prefix(limit).map { entry in
            let profile = profileNames[entry.profileID] ?? "?"
            let status = entry.indexedAt != nil ? "" : (entry.indexError.map { " (not indexed: \($0))" } ?? " (indexing)")
            return "- \(entry.displayTitle) <\(entry.url.absoluteString)> — \(entry.displayDetail), \(profile), saved \(entry.createdAt.formatted(date: .abbreviated, time: .omitted)) [\(entry.id.uuidString)]\(status)"
        }
        var text = "Bookmarks in \(describeScope(scope)) (\(entries.count)):\n" + lines.joined(separator: "\n")
        if entries.count > limit { text += "\n…and \(entries.count - limit) more" }
        return text
    }

    private func searchBookmarks(_ args: ACPJSON) async throws -> String {
        guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw BrowserTool.Failure(message: "query is required")
        }
        let scope = try bookmarkScope(args["profile"])
        let limit = min(30, max(1, args["count"]?.intValue ?? 8))
        let hits = await bookmarks.search(query, in: scope.scope, profileID: scope.profileID, limit: limit)
        guard !hits.isEmpty else { return "No bookmarks match \"\(query)\" in \(describeScope(scope))." }
        let profileNames = Dictionary(browser.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let lines = hits.enumerated().map { index, hit in
            let entry = hit.bookmark
            var line = "\(index + 1). \(entry.displayTitle) <\(entry.url.absoluteString)> — \(profileNames[entry.profileID] ?? "?"), score \(String(format: "%.2f", hit.score)) [\(entry.id.uuidString)]"
            if !hit.snippet.isEmpty { line += "\n   \(hit.snippet.replacingOccurrences(of: "\n", with: " "))" }
            return line
        }
        return "Bookmarks for \"\(query)\" in \(describeScope(scope)):\n\n" + lines.joined(separator: "\n")
    }

    // MARK: Tool bodies

    private func listWorkspaces() throws -> String {
        let layout = browser.layout
        var profiles: [ACPJSON] = []
        for profile in browser.profiles {
            let strip = layout.strip(for: profile.id)
            var workspaces: [ACPJSON] = []
            for (index, workspace) in strip.workspaces.enumerated() where !workspace.isEmpty || !workspace.name.isEmpty {
                let windows: [ACPJSON] = workspace.columns.enumerated().compactMap { position, column in
                    guard let tab = browser.tab(column.tabID) else { return nil }
                    var window: [String: ACPJSON] = [
                        "id": .string(tab.id.uuidString),
                        "title": .string(tab.title),
                        "url": .string(tab.showsStartPage ? "about:start" : tab.currentURL?.absoluteString ?? ""),
                    ]
                    if tab.page.isLoading { window["loading"] = true }
                    if position == workspace.focus { window["focused"] = true }
                    return .object(window)
                }
                var entry: [String: ACPJSON] = ["index": .number(Double(index + 1)), "windows": .array(windows)]
                if !workspace.name.isEmpty { entry["name"] = .string(workspace.name) }
                if index == strip.focus { entry["focused"] = true }
                workspaces.append(.object(entry))
            }
            var entry: [String: ACPJSON] = ["name": .string(profile.name), "workspaces": .array(workspaces)]
            if profile.id == browser.selectedProfileID { entry["onScreen"] = true }
            profiles.append(.object(entry))
        }
        return ACPJSON.object(["profiles": .array(profiles)]).description
    }

    private func webSearch(_ args: ACPJSON) async throws -> String {
        guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw BrowserTool.Failure(message: "query is required")
        }
        let limit = min(25, max(1, args["count"]?.intValue ?? 8))
        let results = try await search.search(query, limit: limit)
        guard !results.isEmpty else {
            throw BrowserTool.Failure(message: "No results for \"\(query)\". Try other words, or open the search page "
                + "itself with open_window(query:) and read it with get_page_links.")
        }
        let lines = results.enumerated().map { index, result in
            var line = "\(index + 1). \(result.title)\n   \(result.url.absoluteString)"
            if !result.snippet.isEmpty { line += "\n   \(result.snippet)" }
            return line
        }
        return "Results for \"\(query)\":\n\n" + lines.joined(separator: "\n")
    }

    private func openWindow(_ args: ACPJSON) throws -> String {
        let profile = try profile(args["profile"])
        let index = try workspaceIndex(args["workspace"], in: profile.id)
        let activate = args["activate"]?.boolValue ?? true
        var url: URL?
        if let raw = args["url"]?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let parsed = URL.fromUserInput(raw) else { throw BrowserTool.Failure(message: "Cannot open \(raw)") }
            url = parsed
        } else if let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            url = SearchEngine.current.searchURL(for: query)
        }
        let tab = browser.newTab(url: url, in: profile.id, workspace: index, activate: activate)
        let place = "\(workspaceTitle(index, in: profile.id)) of \(profile.name)"
        return "Opened window \(tab.id.uuidString) in \(place)" + (url.map { " → \($0.absoluteString)" } ?? " (start page)")
    }

    private func navigate(_ args: ACPJSON) async throws -> String {
        let tab = try tab(args)
        guard let raw = args["url"]?.stringValue, let url = URL.fromUserInput(raw) else { throw BrowserTool.Failure(message: "url is required") }
        tab.load(url)
        await Self.waitForLoad(tab)
        return "\(Self.describe(tab))" + (tab.page.isLoading ? " (still loading)" : "")
    }

    private func pageContent(_ args: ACPJSON) async throws -> String {
        let tab = try tab(args)
        let limit = max(200, args["max_chars"]?.intValue ?? 20_000)
        guard !tab.showsStartPage else { return "\(Self.describe(tab))\n\nThis window shows six's start page; nothing is loaded yet." }
        await Self.waitForLoad(tab)
        let text = await Self.pageText(of: tab.page) ?? ""
        let truncated = text.count > limit ? String(text.prefix(limit)) + "\n…[truncated, \(text.count) characters in total]" : text
        return "\(Self.describe(tab))\n\n\(truncated)"
    }

    private func pageLinks(_ args: ACPJSON) async throws -> String {
        let tab = try tab(args)
        let limit = max(1, args["max_links"]?.intValue ?? 200)
        await Self.waitForLoad(tab)
        let script = """
            return Array.from(document.querySelectorAll('a[href]'))
                .map(a => [a.innerText.trim().replace(/\\s+/g, ' ').slice(0, 120), a.href])
                .filter(([, href]) => /^https?:/.test(href));
            """
        let raw = (try? await tab.page.callJavaScript(script)) as? [[String]] ?? []
        var seen = Set<String>()
        let lines = raw.filter { seen.insert($0[1]).inserted }.prefix(limit).map { "\($0[0].isEmpty ? "(no text)" : $0[0]) — \($0[1])" }
        return "\(Self.describe(tab))\n\n" + (lines.isEmpty ? "No links." : lines.joined(separator: "\n"))
    }

    private func summarize(_ args: ACPJSON) async throws -> String {
        let tab = try tab(args)
        guard !tab.showsStartPage else { throw BrowserTool.Failure(message: "This window shows the start page; nothing to summarize") }
        await Self.waitForLoad(tab)
        let limit = assistant.model == .onDevice ? 6_000 : 24_000
        guard let text = await Self.pageText(of: tab.page, limit: limit) else { throw BrowserTool.Failure(message: "The page has no readable text") }
        let session = try assistant.makeSession(instructions: """
            You summarize web pages for a browser. Be faithful to the page, concise, and write in the page's language \
            unless asked otherwise. Use short paragraphs or bullets.
            """)
        var prompt = "Page: \(tab.title) <\(tab.page.url?.absoluteString ?? "")>\n"
        if let focus = args["focus"]?.stringValue, !focus.isEmpty { prompt += "Focus on: \(focus)\n" }
        prompt += "Page content (truncated):\n\"\"\"\n\(text)\n\"\"\"\n\nSummarize this page."
        let response = try await session.respond(to: prompt)
        return "\(Self.describe(tab))\n\n\(response.content)"
    }

    // MARK: Page helpers

    private static func describe(_ tab: BrowserTab) -> String {
        "\(tab.title) <\(tab.showsStartPage ? "about:start" : tab.currentURL?.absoluteString ?? "")> [\(tab.id.uuidString)]"
    }

    /// Lets a navigation settle before reading the page, bounded so a spinner never blocks an agent.
    private static func waitForLoad(_ tab: BrowserTab, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        // A fresh `load` flips `isLoading` on a tick later; give it a moment.
        try? await Task.sleep(for: .milliseconds(150))
        while tab.page.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func pageText(of page: WebPage, limit: Int = 200_000) async -> String? {
        let script = "return document.body ? document.body.innerText : ''"
        guard let raw = try? await page.callJavaScript(script) as? String else { return nil }
        let collapsed = raw.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }

    private static func describeJavaScriptValue(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}

// MARK: - Foundation Models adapter

/// A `BrowserTool` as a Foundation Models `Tool`, so the ⌘K assistant can call it while answering.
/// Arguments arrive as `GeneratedContent`; they are re-read as JSON, which is what the tool bodies speak.
nonisolated struct BrowserModelTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let body: @Sendable (ACPJSON) async throws -> String

    @MainActor
    init(_ tool: BrowserTool) throws {
        name = tool.name
        description = tool.description
        parameters = try Self.schema(for: tool)
        let run = tool.run
        body = { args in try await MainActor.run { () -> Task<String, Error> in Task { try await run(args) } }.value }
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = (try? JSONDecoder().decode(ACPJSON.self, from: Data(arguments.jsonString.utf8))) ?? [:]
        do {
            return try await body(json)
        } catch let failure as BrowserTool.Failure {
            return "Error: \(failure.message)" // the model can recover from a bad argument; a thrown error ends the turn
        }
    }

    private static func schema(for tool: BrowserTool) throws -> GenerationSchema {
        let properties = tool.parameters.map { parameter in
            let type: DynamicGenerationSchema = switch parameter.type {
            case .string: DynamicGenerationSchema(type: String.self)
            case .integer: DynamicGenerationSchema(type: Int.self)
            case .boolean: DynamicGenerationSchema(type: Bool.self)
            }
            return DynamicGenerationSchema.Property(name: parameter.name, description: parameter.description, schema: type, isOptional: !parameter.required)
        }
        let root = DynamicGenerationSchema(name: tool.name, description: tool.description, properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }
}

// MARK: - MCP descriptor

extension BrowserTool {
    /// `tools/list` entry: name, description and a JSON Schema for the arguments.
    var mcpDescriptor: ACPJSON {
        var properties: [String: ACPJSON] = [:]
        for parameter in parameters {
            properties[parameter.name] = ["type": .string(parameter.type.rawValue), "description": .string(parameter.description)]
        }
        return [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(parameters.filter(\.required).map { .string($0.name) }),
                "additionalProperties": false,
            ],
        ]
    }
}
