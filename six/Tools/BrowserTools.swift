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
    /// The spec's `title`: the human-readable name a client shows instead of `name`
    /// (https://modelcontextprotocol.io/specification/latest/server/tools). Localized — the client
    /// showing it is the user's own.
    var title: String = ""
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

/// The tools, speaking the product's language — windows in workspaces on a profile's rail — over the
/// live `BrowserState`. Everything defaults to what is on screen.
@MainActor
final class BrowserToolCatalog {
    private let browser: BrowserState
    private let assistant: AssistantSettings
    private let bookmarks: BookmarkStore
    private let settings: SettingsStore
    private let highlights: HighlightStore
    /// Console and network capture; the devtools tools say so plainly when it is off.
    var devTools: DevToolsStore?

    init(browser: BrowserState, assistant: AssistantSettings, bookmarks: BookmarkStore, settings: SettingsStore, highlights: HighlightStore) {
        self.browser = browser
        self.assistant = assistant
        self.bookmarks = bookmarks
        self.settings = settings
        self.highlights = highlights
    }

    static let instructions = """
        six is a macOS browser with a niri-style layout. There are no tabs: a page is a *window*, windows sit \
        left to right in a *workspace* (a scrollable rail), workspaces are stacked vertically inside a \
        *profile* (an isolated cookie jar such as "Personal" or "Work"). Exactly one workspace of one profile \
        is on screen; its focused window is what the user is looking at. Tools default to that window, \
        workspace and profile. Window ids come from `list_workspaces`. Workspaces are addressed by name or \
        1-based position; naming one that doesn't exist creates it.

        A rail is meant to be filled. When the user asks you to find, compare or shop for something,         search first (`web_search`), then open the several pages actually worth putting side by side —         different sites, or the same site on the different options — each in its own window, each on the         exact page for what was asked (a route, a product, a date), not a site's front page. Reading a         page yourself (`get_page_content`) is for the answer you write; the windows are what the user is         left with.

        The user also keeps *bookmarks*: pages saved as readable Markdown files (outside your working directory) and \
        indexed by meaning. `search_bookmarks` finds them by topic (any language), `list_bookmarks` lists them, \
        `read_bookmark` returns the saved text, `add_bookmark` saves a window's page. Bookmarks belong to a \
        profile; the user chooses in Settings whether the assistant sees this profile's or every \
        profile's, and a `profile` argument (a name, or `all`) overrides that. When a question is about \
        something the user read or saved, search the bookmarks before searching the web — `search_bookmarks` is the \
        way in, then `read_bookmark`; don't grep or read the `Bookmarks/*.md` files (or the original page) \
        yourself, the tools return the same text with the search already done.

        A *document* is a window that holds Markdown instead of a page — the place to write an answer so it \
        sits on the rail next to the sources it came from, and stays. `create_document` opens one, \
        `write_document` writes into it (whole text, appended, or one `## section` by heading — write the \
        outline first and fill sections in as you read, so the user can watch it grow; never overwrite a \
        section the user is editing), `read_document` reads it back, `cite` adds a numbered source line and \
        returns the `[n]` to use inline. `highlight_page` marks the paragraphs of a page that answer a \
        question and returns links to them (`#:~:text=`) for citations that point at the sentences, not the \
        page. Documents appear in `list_workspaces` with `kind: document`; their id is a window id.

        An *app* is a third kind of window: an interface a connected MCP server drew for one of its own tool \
        calls (`kind: app`, with the server and tool that opened it). You cannot read or drive its page — \
        `get_page_content` returns what the tool was called with and what it answered, and that is all there \
        is to read. The window is the answer; describe it, don't narrate it.

        A connected server's own tools are named `<server>__<tool>` and listed here with the rest. \
        When one of them answers what was asked, call it — do not open that service's website \
        instead. A question naming a service six is connected to (its cards, its issues, its \
        inbox) is a question for that server's tool; the web is what the browser has for the \
        services it is not connected to.
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
        name: "profile", description: "Profile name, or `all`. Default: the scope the user chose in Settings.")

    private static let windowID = BrowserTool.Parameter(
        name: "window_id", description: "Window id from list_workspaces (a prefix is enough). Default: the focused window.")

    private static let documentID = BrowserTool.Parameter(
        name: "document_id", description: "The document window's id (a prefix is enough). Default: the research run's document in the on-screen workspace, or the only document there.")

    private lazy var all: [BrowserTool] = [
        BrowserTool(
            name: "list_workspaces",
            title: String(localized: "List Workspaces"),
            description: "Every profile with its workspaces and the windows (id, title, URL) in each; marks what is focused and on screen.",
            run: { [unowned self] _ in try self.listWorkspaces() }
        ),
        BrowserTool(
            name: "web_search",
            title: String(localized: "Search the Web"),
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
            title: String(localized: "Open Window"),
            description: "Opens a new window with a URL, or a web search for `query`. Goes into the on-screen workspace of the "
                + "current profile unless `workspace` (name or 1-based index; a new name creates the workspace) and/or "
                + "`profile` (name) say otherwise. Returns the new window id.",
            parameters: [
                .init(name: "url", description: "Address to load. Scheme-less hosts get https://."),
                .init(name: "query", description: "Search query, used when `url` is absent."),
                .init(name: "workspace", description: "Workspace name or 1-based index. Default: the on-screen workspace."),
                .init(name: "profile", description: "Profile name. Default: the current profile."),
                .init(name: "activate", description: "Focus the new window (default true). false adds it in the background.", type: .boolean),
                .init(name: "private", description: "Open in private browsing (in-memory session, nothing recorded); ignores `workspace` and `profile`.", type: .boolean),
            ],
            run: { [unowned self] args in try self.openWindow(args) }
        ),
        BrowserTool(
            name: "navigate",
            title: String(localized: "Go to Address"),
            description: "Loads a URL (or a search query) in an existing window and waits for the page to finish loading.",
            parameters: [Self.windowID, .init(name: "url", description: "Address or search text.", required: true)],
            run: { [unowned self] args in try await self.navigate(args) }
        ),
        BrowserTool(
            name: "get_page_content",
            title: String(localized: "Read Page"),
            description: "The visible text of a window's page (waits for loading to finish), with title and URL. Defaults to the focused window.",
            parameters: [Self.windowID, .init(name: "max_chars", description: "Truncate the text to this many characters (default 20000).", type: .integer)],
            run: { [unowned self] args in try await self.pageContent(args) }
        ),
        BrowserTool(
            name: "get_selection",
            title: String(localized: "Read Selection"),
            description: "The text the reader has selected on a window's page, with the page's title, URL and language. "
                + "Empty when nothing is selected. Use it when the user refers to \"this\", \"the selected text\" or "
                + "\"what I highlighted\" — including asking for it to be translated or explained.",
            parameters: [Self.windowID],
            run: { [unowned self] args in try await self.pageSelection(args) }
        ),
        BrowserTool(
            name: "get_page_links",
            title: String(localized: "Page Links"),
            description: "Links on a window's page as `text — URL` lines, in document order. Defaults to the focused window.",
            parameters: [Self.windowID, .init(name: "max_links", description: "At most this many links (default 200).", type: .integer)],
            run: { [unowned self] args in try await self.pageLinks(args) }
        ),
        BrowserTool(
            name: "summarize_page",
            title: String(localized: "Summarize Page"),
            description: "Summarizes a window's page with the browser's own assistant model (the one chosen in ⌘K: on-device, "
                + "Private Cloud Compute or Claude). `focus` narrows the summary to a question or aspect.",
            parameters: [Self.windowID, .init(name: "focus", description: "What the summary should concentrate on, if anything.")],
            surfaces: .mcp,
            run: { [unowned self] args in try await self.summarize(args) }
        ),
        BrowserTool(
            name: "list_console_messages",
            title: String(localized: "Console Messages"),
            description: "What a window's page logged — console messages and uncaught errors, oldest first, since it last "
                + "navigated. Needs Develop › Capture Console and Network to be on; the tool says so if it is not.",
            parameters: [
                Self.windowID,
                .init(name: "level", description: "Only this level: log, info, warn, error or debug."),
                .init(name: "limit", description: "At most this many, most recent (default 100).", type: .integer),
            ],
            surfaces: .mcp,
            run: { [unowned self] args in try self.consoleMessages(args) }
        ),
        BrowserTool(
            name: "list_network_requests",
            title: String(localized: "Network Requests"),
            description: "The requests a window's page made since it last navigated — URL, method, status, duration — as the "
                + "page itself saw them. Needs Develop › Capture Console and Network to be on.",
            parameters: [
                Self.windowID,
                .init(name: "failed_only", description: "Only requests that failed or answered 4xx/5xx.", type: .boolean),
                .init(name: "limit", description: "At most this many, most recent (default 100).", type: .integer),
            ],
            surfaces: .mcp,
            run: { [unowned self] args in try self.networkRequests(args) }
        ),
        BrowserTool(
            name: "take_screenshot",
            title: String(localized: "Take Screenshot"),
            description: "Writes a PNG of a window's page to disk and returns the path — what the page looks like right now.",
            parameters: [Self.windowID],
            surfaces: .mcp,
            run: { [unowned self] args in try await self.screenshot(args) }
        ),
        BrowserTool(
            name: "focus_window",
            title: String(localized: "Focus Window"),
            description: "Brings a window on screen: switches to its profile and workspace and scrolls the rail to it.",
            parameters: [.init(name: "window_id", description: "Window id from list_workspaces (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                self.browser.selectTab(tab.id)
                return "Focused \(Self.describe(tab))"
            }
        ),
        BrowserTool(
            name: "move_window",
            title: String(localized: "Move Window"),
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
            name: "move_window_to_profile",
            title: String(localized: "Move Window to Profile"),
            description: "Moves a window to another profile: the same page, reopened with that profile's cookies and "
                + "extensions — so it comes back signed in as that profile, or not at all. The window keeps its id; "
                + "the browser switches to the profile it went to.",
            parameters: [
                .init(name: "window_id", description: "Window id from list_workspaces (a prefix is enough).", required: true),
                .init(name: "profile", description: "Profile name, from list_workspaces.", required: true),
            ],
            run: { [unowned self] args in
                let tab = try self.tab(args)
                let profile = try self.profile(args["profile"])
                guard let moved = self.browser.moveTab(tab.id, toProfile: profile.id) else {
                    throw BrowserTool.Failure(message: tab.profileID == profile.id
                        ? "\(Self.describe(tab)) is already in \(profile.name)"
                        : "\(Self.describe(tab)) can't go to \(profile.name): a document window can't enter a private profile")
                }
                return "Moved \(Self.describe(moved)) to \(profile.name)"
            }
        ),
        BrowserTool(
            name: "close_window",
            title: String(localized: "Close Window"),
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
            title: String(localized: "List Bookmarks"),
            description: "The user's bookmarks, newest first: id, title, URL, site and when it was saved. Scope: the "
                + "profile named in `profile`, `all` profiles, or the user's chosen scope by default.",
            parameters: [Self.bookmarkProfile, .init(name: "limit", description: "At most this many (default 50).", type: .integer)],
            run: { [unowned self] args in try self.listBookmarks(args) }
        ),
        BrowserTool(
            name: "search_bookmarks",
            title: String(localized: "Search Bookmarks"),
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
            title: String(localized: "Read Bookmark"),
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
            title: String(localized: "Add Bookmark"),
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
            name: "refresh_bookmark",
            title: String(localized: "Refresh Bookmark"),
            description: "Re-reads a bookmark's page from its site (off screen, with the profile's cookies) and re-indexes it "
                + "if the text changed. Pages are also re-read on a schedule; this is for when you need it now.",
            parameters: [.init(name: "bookmark_id", description: "Bookmark id (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let bookmark = try self.bookmarks.bookmark(matching: args["bookmark_id"]?.stringValue ?? "")
                await self.bookmarks.refresh(bookmark.id)
                guard let after = self.bookmarks.bookmark(bookmark.id) else { throw BrowserTool.Failure(message: "Bookmark vanished") }
                if let error = after.refreshError { throw BrowserTool.Failure(message: "Refresh failed: \(error)") }
                let changed = after.contentHash != bookmark.contentHash
                return "\(changed ? "Updated" : "Unchanged"): \(after.displayTitle) <\(after.url.absoluteString)> (\(after.characterCount) characters)"
            }
        ),
        BrowserTool(
            name: "remove_bookmark",
            title: String(localized: "Remove Bookmark"),
            description: "Deletes a bookmark and its saved file.",
            parameters: [.init(name: "bookmark_id", description: "Bookmark id (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let bookmark = try self.bookmarks.bookmark(matching: args["bookmark_id"]?.stringValue ?? "")
                self.bookmarks.remove(bookmark.id)
                return "Removed bookmark \(bookmark.displayTitle) <\(bookmark.url.absoluteString)>"
            }
        ),
        BrowserTool(
            name: "create_document",
            title: String(localized: "New Document"),
            description: "Opens a document window — Markdown text in a column of the rail, next to the pages. Goes into the "
                + "on-screen workspace of the current profile unless `workspace` / `profile` say otherwise. Returns its id.",
            parameters: [
                .init(name: "title", description: "The document's title (becomes the `# ` heading)."),
                .init(name: "markdown", description: "Initial text; overrides `title` when given."),
                .init(name: "workspace", description: "Workspace name or 1-based index. Default: the on-screen workspace."),
                .init(name: "profile", description: "Profile name. Default: the current profile."),
                .init(name: "activate", description: "Focus the new window (default true).", type: .boolean),
            ],
            run: { [unowned self] args in
                let profile = try self.profile(args["profile"])
                let index = try self.workspaceIndex(args["workspace"], in: profile.id)
                var text = args["markdown"]?.stringValue ?? ""
                if text.isEmpty, let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespaces), !title.isEmpty { text = "# \(title)\n" }
                let tab = self.browser.newDocument(text: text, in: profile.id, workspace: index, activate: args["activate"]?.boolValue ?? true)
                return "Created document \(tab.id.uuidString) in \(self.workspaceTitle(index, in: profile.id)) of \(profile.name)"
            }
        ),
        BrowserTool(
            name: "write_document",
            title: String(localized: "Write Document"),
            description: "Writes into a document window. `mode` is `replace` (the whole text), `append` (below the end), or "
                + "`section` (replace the body of the `## section` whose heading matches `section`, keeping the heading; a "
                + "heading that doesn't exist is added at the end). Write the outline first, then fill the sections in.",
            parameters: [
                Self.documentID,
                .init(name: "markdown", description: "The Markdown to write.", required: true),
                .init(name: "mode", description: "`replace`, `append` or `section` (default `append`)."),
                .init(name: "section", description: "Heading text of the section to replace, for `mode: section`."),
            ],
            run: { [unowned self] args in try self.writeDocument(args) }
        ),
        BrowserTool(
            name: "read_document",
            title: String(localized: "Read Document"),
            description: "The current Markdown of a document window, so what was written (by you or the user) can be revised.",
            parameters: [Self.documentID],
            run: { [unowned self] args in
                let (tab, document) = try self.documentTab(args)
                let sections = document.sections.map { "\(String(repeating: "#", count: $0.level)) \($0.heading)" }
                return "\(Self.describe(tab))\n\(document.text.count) characters; sections: \(sections.isEmpty ? "none" : sections.joined(separator: " · "))\n\n\(document.text)"
            }
        ),
        BrowserTool(
            name: "cite",
            title: String(localized: "Cite a Source"),
            description: "Adds a source to the document's `## Sources` list — title, URL, retrieved-at and optionally the passage — "
                + "and returns the `[n]` to put inline. Point it at a window (`window_id`, default: the focused page) or give "
                + "`url` and `title` directly; a `highlight_id` from highlight_page makes the source line link to the passage.",
            parameters: [
                Self.documentID,
                Self.windowID,
                .init(name: "url", description: "Source URL, when not citing a window."),
                .init(name: "title", description: "Source title, when not citing a window."),
                .init(name: "passage", description: "The sentences that earned the citation, quoted."),
                .init(name: "highlight_id", description: "A highlight from highlight_page; its link becomes the source's URL."),
            ],
            run: { [unowned self] args in try self.cite(args) }
        ),
        BrowserTool(
            name: "highlight_page",
            title: String(localized: "Highlight Page"),
            description: "Marks the paragraphs of a window's page that answer `question` (the browser's own model picks them by "
                + "number from the page's blocks, so nothing is retyped) and returns each as a highlight: id, the exact text, and a "
                + "`#:~:text=` link that scrolls to it in any browser. Highlights persist per URL and are painted again when the "
                + "page is reopened. `blocks` picks paragraphs by number yourself instead (from list_page_blocks).",
            parameters: [
                Self.windowID,
                .init(name: "question", description: "What the passages should answer."),
                .init(name: "blocks", description: "Comma-separated block numbers to mark directly (skips the model)."),
                .init(name: "max", description: "At most this many passages (default 3).", type: .integer),
            ],
            run: { [unowned self] args in try await self.highlightPage(args) }
        ),
        BrowserTool(
            name: "list_page_blocks",
            title: String(localized: "List Page Blocks"),
            description: "The paragraph-ish blocks of a window's page, numbered, with their text — what highlight_page chooses "
                + "from. For picking passages yourself and passing the numbers as `blocks`.",
            parameters: [Self.windowID, .init(name: "max_chars", description: "Truncate the listing to this many characters (default 20000).", type: .integer)],
            run: { [unowned self] args in
                let tab = try self.webTab(args)
                await Self.waitForLoad(tab)
                let (unsupported, blocks) = try await self.pageBlocks(tab)
                if let unsupported { throw BrowserTool.Failure(message: unsupported) }
                let limit = max(500, args["max_chars"]?.intValue ?? 20_000)
                let text = blocks.map { "\($0.n): \($0.text)" }.joined(separator: "\n")
                return "\(Self.describe(tab))\n\n" + (text.count > limit ? String(text.prefix(limit)) + "\n…[truncated]" : text)
            }
        ),
        BrowserTool(
            name: "list_highlights",
            title: String(localized: "List Highlights"),
            description: "The highlights stored for a window's page (or for `url`): id, text, note and the `#:~:text=` link.",
            parameters: [Self.windowID, .init(name: "url", description: "A page URL, instead of a window.")],
            run: { [unowned self] args in
                let url: URL
                var heading: String
                if let raw = args["url"]?.stringValue, let parsed = URL(string: raw) {
                    url = parsed
                    heading = parsed.absoluteString
                } else {
                    let tab = try self.webTab(args)
                    guard let current = tab.currentURL else { throw BrowserTool.Failure(message: "Nothing is loaded in this window") }
                    url = current
                    heading = Self.describe(tab)
                }
                let stored = self.highlights.highlights(for: url)
                guard !stored.isEmpty else { return "No highlights on \(heading)" }
                return "Highlights on \(heading):\n\n" + stored.map(Self.describe).joined(separator: "\n\n")
            }
        ),
        BrowserTool(
            name: "remove_highlight",
            title: String(localized: "Remove Highlight"),
            description: "Deletes a highlight.",
            parameters: [.init(name: "highlight_id", description: "Highlight id (a prefix is enough).", required: true)],
            run: { [unowned self] args in
                let highlight = try self.highlights.highlight(matching: args["highlight_id"]?.stringValue ?? "")
                self.highlights.remove(highlight.id)
                for tab in self.browser.tabs where tab.currentURL.map({ Highlight.key(for: $0) }) == highlight.url {
                    _ = try? await tab.page.six(HighlightScript.remove, arguments: ["id": highlight.id.uuidString])
                }
                return "Removed highlight \(highlight.id.uuidString)"
            }
        ),
        BrowserTool(
            name: "evaluate_javascript",
            title: String(localized: "Run JavaScript"),
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

    /// A window that is a page, for the tools that read or drive one.
    /// A window that is a page, for the tools that read or drive one.
    ///
    /// `allowsApps` is for the three that only *watch* — a picture of the window, its console, its
    /// network. Everything else is refused for an app: its own document is in a frame six never
    /// scripts, so reading or driving it here would reach only the shell around it, and the shell is
    /// the bridge to the app's server, which is not somewhere a tool call belongs.
    private func webTab(_ args: ACPJSON, allowsApps: Bool = false) throws -> BrowserTab {
        let tab = try tab(args)
        guard !tab.isDocument else { throw BrowserTool.Failure(message: "\(Self.describe(tab)) is a document, not a page; use read_document / write_document") }
        guard allowsApps || !tab.isApp else {
            throw BrowserTool.Failure(message: "\(Self.describe(tab)) is an MCP app, not a page; use get_page_content for what it is showing")
        }
        // A restored app window has no page at all yet — reaching for one would build a web view for
        // a window that is showing a card.
        guard tab.pendingApp == nil else {
            throw BrowserTool.Failure(message: "\(Self.describe(tab)) is a restored MCP app that has not been run again; use get_page_content")
        }
        return tab
    }

    /// The document window a tool works on: `document_id` (a window id), or the run's document in the
    /// focused workspace, or the only document on screen.
    private func documentTab(_ args: ACPJSON) throws -> (BrowserTab, TextDocument) {
        if let raw = args["document_id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let tab = try tab(["window_id": .string(raw)])
            guard let document = tab.document else { throw BrowserTool.Failure(message: "\(Self.describe(tab)) is a page, not a document") }
            return (tab, document)
        }
        if let run = browser.focusedRun, let tab = browser.tab(run.documentTabID), let document = tab.document { return (tab, document) }
        let visible = browser.layout.focusedWorkspace?.columns.compactMap { browser.tab($0.tabID) }.filter(\.isDocument) ?? []
        if visible.count == 1, let document = visible[0].document { return (visible[0], document) }
        if let selected = browser.selectedTab, let document = selected.document { return (selected, document) }
        throw BrowserTool.Failure(message: visible.isEmpty ? "No document window; call create_document first" : "Several documents are open; pass document_id")
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

    /// A name (created when missing) or a 1-based position; nil means the rail's focused workspace.
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
                    if let document = tab.document {
                        window["kind"] = "document"
                        window["url"] = .string("six://document/\(document.id.uuidString)")
                        window["characters"] = .number(Double(document.text.count))
                    } else if let saved = tab.pendingApp {
                        window["kind"] = "app"
                        window["url"] = .string(saved.resourceURI)
                        window["server"] = .string(saved.serverName)
                        window["tool"] = .string(saved.tool)
                        window["restored"] = true
                    } else if let app = tab.app {
                        window["kind"] = "app"
                        window["url"] = .string(app.resource.uri)
                        window["server"] = .string(app.server.name)
                        window["tool"] = .string(app.tool.name)
                    } else if tab.isLoading { window["loading"] = true }
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
            if profile.isPrivate { entry["private"] = true }
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
        if args["private"]?.boolValue == true {
            var url: URL?
            if let raw = args["url"]?.stringValue, !raw.isEmpty { url = URL.fromUserInput(raw) }
            else if let query = args["query"]?.stringValue, !query.isEmpty { url = SearchEngine.current.searchURL(for: query) }
            let tab = browser.newPrivateWindow(url: url)
            return "Opened private window \(tab.id.uuidString)" + (url.map { " → \($0.absoluteString)" } ?? " (start page)")
        }
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
        browser.noteSource(tab, workspace: index)
        let place = "\(workspaceTitle(index, in: profile.id)) of \(profile.name)"
        return "Opened window \(tab.id.uuidString) in \(place)" + (url.map { " → \($0.absoluteString)" } ?? " (start page)")
    }

    private func navigate(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args)
        guard let raw = args["url"]?.stringValue, let url = URL.fromUserInput(raw) else { throw BrowserTool.Failure(message: "url is required") }
        tab.load(url)
        await Self.waitForLoad(tab)
        return "\(Self.describe(tab))" + (tab.isLoading ? " (still loading)" : "")
    }

    // MARK: Developer tools

    private func requireCapture() throws -> DevToolsStore {
        guard let devTools else { throw BrowserTool.Failure(message: "Developer tools are not available in this build.") }
        guard devTools.isCapturing else {
            throw BrowserTool.Failure(message: "Console and network capture is off. Turn on Develop › Capture Console and Network, "
                + "then reload the page — the hooks run from the start of a load.")
        }
        return devTools
    }

    private func consoleMessages(_ args: ACPJSON) throws -> String {
        let tab = try webTab(args, allowsApps: true)
        let devTools = try requireCapture()
        let limit = max(1, args["limit"]?.intValue ?? 100)
        let messages = devTools.consoleMessages(for: tab.id, level: args["level"]?.stringValue, limit: limit)
        guard !messages.isEmpty else { return "\(Self.describe(tab))\n\nNothing logged since this window last navigated." }
        let lines = messages.map { "[\($0.level)] \($0.text)" }
        return "\(Self.describe(tab))\n\n" + lines.joined(separator: "\n")
    }

    private func networkRequests(_ args: ACPJSON) throws -> String {
        let tab = try webTab(args, allowsApps: true)
        let devTools = try requireCapture()
        let limit = max(1, args["limit"]?.intValue ?? 100)
        let failedOnly = args["failed_only"]?.boolValue ?? false
        let requests = devTools.networkRequests(for: tab.id, failedOnly: failedOnly, limit: limit)
        guard !requests.isEmpty else {
            return "\(Self.describe(tab))\n\n\(failedOnly ? "No failed requests" : "No requests") since this window last navigated."
        }
        let lines = requests.map { entry in
            "\(entry.method) \(entry.statusText) \(entry.milliseconds) ms\(entry.sizeText) [\(entry.kind)] \(entry.url)"
        }
        return "\(Self.describe(tab))\n\n" + lines.joined(separator: "\n")
    }

    private func screenshot(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args, allowsApps: true)
        await Self.waitForLoad(tab)
        // The whole page, not the part on screen — a screenshot of a column is not what was asked for.
        guard let data = try? await tab.page.exported(as: .image(region: .contents, snapshotWidth: 1200)) else {
            throw BrowserTool.Failure(message: "Could not take a picture of this window.")
        }
        try? FileManager.default.createDirectory(at: DevToolsStore.screenshotFolder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let file = DevToolsStore.screenshotFolder.appending(path: "\(stamp)-\(tab.id.uuidString.prefix(8)).png")
        try data.write(to: file)
        return "\(Self.describe(tab))\n\nWrote \(data.count / 1024) KB to \(file.path)"
    }

    private func pageContent(_ args: ACPJSON) async throws -> String {
        let tab = try tab(args)
        if let document = tab.document { return "\(Self.describe(tab))\n\n\(document.text)" }
        if let app = tab.app { return "\(Self.describe(tab))\n\n\(app.summaryForModel)" }
        if let saved = tab.pendingApp {
            return """
                \(Self.describe(tab))

                MCP app \(saved.tool) from \(saved.serverName) (\(saved.resourceURI)), restored from the \
                previous launch and not running. It was called with: \(saved.toolArguments)
                The tool has not been run again — six only does that by itself for a tool the server \
                marks read-only. Ask the user before running it.
                """
        }
        let limit = max(200, args["max_chars"]?.intValue ?? 20_000)
        guard !tab.showsStartPage else { return "\(Self.describe(tab))\n\nThis window shows six's start page; nothing is loaded yet." }
        await Self.waitForLoad(tab)
        let text = await Self.pageText(of: tab.page) ?? ""
        let truncated = text.count > limit ? String(text.prefix(limit)) + "\n…[truncated, \(text.count) characters in total]" : text
        return "\(Self.describe(tab))\n\n\(truncated)"
    }

    /// What the reader has selected, for a model to do something with.
    ///
    /// This is the whole of six's answer to "translate this with a model". Apple's translator is
    /// wired into the page and into the address field because it is free, local and fast; a language
    /// model is none of those over a thousand segments, so it does not get a second engine behind
    /// the translator. It gets this instead — the selection, handed to ⌘K and to every MCP client,
    /// where the model translates or explains it in the conversation and the reader sees what it
    /// did. No new interface, and nothing to pay for when nobody asks.
    private func pageSelection(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args)
        let value = try? await tab.page.six(TranslationScript.selection)
        let text = ((value as? [String: Any])?["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "\(Self.describe(tab))\n\nNothing is selected on this page."
        }
        // The page's own language, so a model asked to translate knows what from without guessing.
        let plan = try? await tab.page.six(TranslationScript.plan)
        let language = (plan as? [String: Any])?["language"] as? String ?? ""
        let header = language.isEmpty ? Self.describe(tab) : "\(Self.describe(tab))\nPage language: \(language)"
        return "\(header)\n\nSelected text:\n\(text)"
    }

    private func pageLinks(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args)
        let limit = max(1, args["max_links"]?.intValue ?? 200)
        await Self.waitForLoad(tab)
        let script = """
            return Array.from(document.querySelectorAll('a[href]'))
                .map(a => [a.innerText.trim().replace(/\\s+/g, ' ').slice(0, 120), a.href])
                .filter(([, href]) => /^https?:/.test(href));
            """
        let raw = (try? await tab.page.six(script)) as? [[String]] ?? []
        var seen = Set<String>()
        let lines = raw.filter { seen.insert($0[1]).inserted }.prefix(limit).map { "\($0[0].isEmpty ? "(no text)" : $0[0]) — \($0[1])" }
        return "\(Self.describe(tab))\n\n" + (lines.isEmpty ? "No links." : lines.joined(separator: "\n"))
    }

    private func summarize(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args)
        guard !tab.showsStartPage else { throw BrowserTool.Failure(message: "This window shows the start page; nothing to summarize") }
        await Self.waitForLoad(tab)
        let limit = assistant.model == .onDevice ? 6_000 : 24_000
        guard let text = await Self.pageText(of: tab.page, limit: limit) else { throw BrowserTool.Failure(message: "The page has no readable text") }
        let session = try assistant.makeSession(instructions: """
            You summarize web pages for a browser. Be faithful to the page, concise, and write in the page's language \
            unless asked otherwise. Use short paragraphs or bullets.
            """)
        var prompt = "Page: \(tab.title) <\(tab.currentURL?.absoluteString ?? "")>\n"
        if let focus = args["focus"]?.stringValue, !focus.isEmpty { prompt += "Focus on: \(focus)\n" }
        prompt += "Page content (truncated):\n\"\"\"\n\(text)\n\"\"\"\n\nSummarize this page."
        let response = try await session.respond(to: prompt)
        return "\(Self.describe(tab))\n\n\(response.content)"
    }

    // MARK: Documents

    private func writeDocument(_ args: ACPJSON) throws -> String {
        let (tab, document) = try documentTab(args)
        guard let markdown = args["markdown"]?.stringValue else { throw BrowserTool.Failure(message: "markdown is required") }
        let mode = args["mode"]?.stringValue?.lowercased() ?? "append"
        switch mode {
        case "replace":
            document.text = markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        case "append":
            document.append(markdown)
        case "section":
            guard let section = args["section"]?.stringValue?.trimmingCharacters(in: .whitespaces), !section.isEmpty else {
                throw BrowserTool.Failure(message: "section (the heading text) is required for mode: section")
            }
            let existed = document.section(named: section) != nil
            document.replaceSection(section, with: markdown)
            return "\(existed ? "Replaced" : "Added") section \"\(section)\" of \(Self.describe(tab)); \(document.text.count) characters now"
        default:
            throw BrowserTool.Failure(message: "mode must be replace, append or section")
        }
        return "Wrote \(markdown.count) characters (\(mode)) into \(Self.describe(tab)); \(document.text.count) characters now"
    }

    private func cite(_ args: ACPJSON) throws -> String {
        let (tab, document) = try documentTab(args)
        var url: URL?
        var title = args["title"]?.stringValue ?? ""
        var passage = args["passage"]?.stringValue
        if let raw = args["highlight_id"]?.stringValue, !raw.isEmpty {
            let highlight = try highlights.highlight(matching: raw)
            url = URL(string: highlight.textFragmentURL) ?? URL(string: highlight.url)
            if title.isEmpty { title = highlight.pageTitle }
            if passage == nil || passage?.isEmpty == true { passage = highlight.exact }
        } else if let raw = args["url"]?.stringValue, let parsed = URL(string: raw) {
            url = parsed
        } else {
            let source = try webTab(args)
            guard let current = source.currentURL else { throw BrowserTool.Failure(message: "\(Self.describe(source)) has nothing loaded to cite") }
            url = current
            if title.isEmpty { title = source.title }
        }
        guard let url else { throw BrowserTool.Failure(message: "Give a window_id, a url or a highlight_id") }
        if title.isEmpty { title = url.host() ?? url.absoluteString }
        let number = document.cite(title: title, url: url, passage: passage)
        return "[\(number)] — \(title) <\(url.absoluteString)> in \(Self.describe(tab)). Use [\(number)] inline."
    }

    // MARK: Highlights

    private struct PageBlock { var n: Int; var text: String }

    private func pageBlocks(_ tab: BrowserTab) async throws -> (unsupported: String?, blocks: [PageBlock]) {
        let value = try await tab.page.six(HighlightScript.blocks)
        guard let object = value as? [String: Any] else { throw BrowserTool.Failure(message: "The page didn't answer") }
        let unsupported = (object["unsupported"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let blocks = (object["blocks"] as? [[String: Any]] ?? []).compactMap { entry -> PageBlock? in
            guard let n = entry["n"] as? Int, let text = entry["text"] as? String else { return nil }
            return PageBlock(n: n, text: text)
        }
        return (unsupported, blocks)
    }

    private func highlightPage(_ args: ACPJSON) async throws -> String {
        let tab = try webTab(args)
        guard let url = tab.currentURL else { throw BrowserTool.Failure(message: "Nothing is loaded in this window") }
        guard !browser.isPrivate(tab.profileID) else { throw BrowserTool.Failure(message: "This window is in private browsing; highlights are not kept there — cite the URL instead") }
        await Self.waitForLoad(tab)
        let (unsupported, blocks) = try await pageBlocks(tab)
        if let unsupported { throw BrowserTool.Failure(message: unsupported) }
        guard !blocks.isEmpty else { throw BrowserTool.Failure(message: "The page has no paragraphs to highlight") }
        let limit = max(1, min(10, args["max"]?.intValue ?? 3))
        let question = args["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var chosen: [(n: Int, reason: String)] = []
        if let raw = args["blocks"]?.stringValue, !raw.isEmpty {
            chosen = raw.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.prefix(limit).map { ($0, question) }
        } else {
            guard !question.isEmpty else { throw BrowserTool.Failure(message: "question (or blocks) is required") }
            chosen = try await chooseBlocks(blocks, question: question, limit: limit)
        }
        let valid = chosen.filter { pick in blocks.contains { $0.n == pick.n } }
        guard !valid.isEmpty else { return "\(Self.describe(tab))\n\nNo passage on this page answers \"\(question)\"." }
        let selectors = try await tab.page.six(HighlightScript.blockSelectors, arguments: ["numbers": valid.map(\.n)]) as? [[String: Any]] ?? []
        var made: [Highlight] = []
        for entry in selectors {
            let n = entry["n"] as? Int
            let note = valid.first { $0.n == n }?.reason ?? question
            // The same passage marked twice stays one highlight.
            if let existing = highlights.highlights(for: url).first(where: { $0.exact == entry["exact"] as? String }) {
                made.append(existing)
                continue
            }
            guard let highlight = Highlight(url: Highlight.key(for: url), script: entry, note: note, pageTitle: tab.title) else { continue }
            highlights.add(highlight)
            highlights.paint(highlight, in: tab)
            made.append(highlight)
        }
        guard !made.isEmpty else { throw BrowserTool.Failure(message: "The chosen blocks could not be anchored on the page") }
        return "\(Self.describe(tab))\n\n" + made.map(Self.describe).joined(separator: "\n\n")
    }

    /// The numbered-block pass: the model sees the numbers and the text and answers with numbers.
    /// It never handles the text it is choosing, so it cannot corrupt it.
    private func chooseBlocks(_ blocks: [PageBlock], question: String, limit: Int) async throws -> [(n: Int, reason: String)] {
        let budget = assistant.model == .onDevice || assistant.model.isAgent ? 6_000 : 30_000
        var listing = ""
        for block in blocks {
            let line = "\(block.n): \(block.text.prefix(300))\n"
            if listing.count + line.count > budget { break }
            listing += line
        }
        let instructions = """
            You pick the numbered paragraphs of a web page that answer a question. Answer with the numbers only, \
            most relevant first, at most \(limit), one per line as `N: reason` where the reason is a few words. \
            Answer `none` if nothing on the page answers it. Never quote the paragraphs.
            """
        // "Which of these is about X" is within the on-device model's reach, so when ⌘K is set to an agent
        // (not a language model) or its model isn't usable, that is the fallback.
        let session: LanguageModelSession
        if !assistant.model.isAgent, let chosen = try? assistant.makeSession(instructions: instructions) {
            session = chosen
        } else {
            let system = SystemLanguageModel.default
            guard case .available = system.availability else {
                throw BrowserTool.Failure(message: "No model to choose passages with: the on-device model is not available (\(system.availability)); pass `blocks` from list_page_blocks instead")
            }
            session = LanguageModelSession(model: system, instructions: instructions)
        }
        let response = try await session.respond(to: "Question: \(question)\n\nParagraphs:\n\(listing)")
        var picks: [(n: Int, reason: String)] = []
        for line in response.content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let n = Int(first.trimmingCharacters(in: CharacterSet(charactersIn: " -*[]."))) else { continue }
            let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if !picks.contains(where: { $0.n == n }) { picks.append((n, reason)) }
            if picks.count == limit { break }
        }
        return picks
    }

    private static func describe(_ highlight: Highlight) -> String {
        var text = "- [\(highlight.id.uuidString)] \"\(highlight.exact.prefix(300))\""
        if !highlight.note.isEmpty { text += "\n  note: \(highlight.note)" }
        text += "\n  link: \(highlight.textFragmentURL)"
        return text
    }

    // MARK: Page helpers

    private static func describe(_ tab: BrowserTab) -> String {
        if let document = tab.document { return "\(document.title) <six://document/\(document.id.uuidString)> [\(tab.id.uuidString)]" }
        return "\(tab.title) <\(tab.showsStartPage ? "about:start" : tab.currentURL?.absoluteString ?? "")> [\(tab.id.uuidString)]"
    }

    /// Lets a navigation settle before reading the page, bounded so a spinner never blocks an agent.
    private static func waitForLoad(_ tab: BrowserTab, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        // A fresh `load` flips `isLoading` on a tick later; give it a moment.
        try? await Task.sleep(for: .milliseconds(150))
        while tab.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func pageText(of page: WebPage, limit: Int = 200_000) async -> String? {
        let script = "return document.body ? document.body.innerText : ''"
        guard let raw = try? await page.six(script) as? String else { return nil }
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
        var descriptor: [String: ACPJSON] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(parameters.filter(\.required).map { .string($0.name) }),
                "additionalProperties": false,
            ],
        ]
        if !title.isEmpty { descriptor["title"] = .string(title) }
        return .object(descriptor)
    }
}
