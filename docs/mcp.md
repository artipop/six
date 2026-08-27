# MCP server (`six --mcp`)

The app binary doubles as an [MCP](https://modelcontextprotocol.io) server, so an ACP agent (or anything else that
speaks MCP over stdio) can drive the browser: open windows into workspaces, read pages, summarize them.

```
agent ──stdio──▶ six --mcp ──unix socket──▶ six.app (MCPHost → MCPServer → BrowserState)
```

- `six --mcp` (`MCPStdioBridge`) is a byte pump: MCP-over-stdio and the app's socket are both newline-delimited
  JSON-RPC, so it forwards lines untouched. It runs before AppKit is loaded — no Dock icon, no window. If the app
  isn't running it launches it (`open -g`) and waits up to 20 s for the socket.
- The running app listens on `~/Library/Application Support/six/mcp.sock` (mode 0600; override with
  `SIX_MCP_SOCKET`). `MCPHost` gives each client its own `JSONRPCConnection` — the same transport the ACP client
  uses — and `MCPServer` answers `initialize`, `ping`, `tools/list`, `tools/call` on the main actor. The tools
  themselves live in `BrowserToolCatalog` (`six/Tools/`), shared with the ⌘K assistant (see [assistant.md](assistant.md)).
- The agent panel passes the server to every ACP session (`session/new` → `mcpServers: [{name: "six",
  command: <this binary>, args: ["--mcp"]}]`), so Claude Code sees the tools as `mcp__six__*` and asks for permission
  through the panel as for any other tool.

## Tools

Vocabulary is the product's: a *window* (page) in a *workspace* (strip) of a *profile*. Everything defaults to what
is on screen — the current profile, its focused workspace, its focused window. Workspaces are addressed by name or
1-based index; a name that doesn't exist is created (the trailing empty workspace gets the name, so it survives being
empty, like a named workspace in niri).

| tool | what it does |
|---|---|
| `list_workspaces` | every profile → workspaces → windows (`id`, `title`, `url`, `focused`, `loading`), with what is on screen |
| `web_search` | ranked results — title, URL, snippet — without opening anything (`query`, `count`) |
| `open_window` | `url` or `query` (search); optional `workspace`, `profile`, `activate` (false = add in the background, nothing on screen moves) |
| `navigate` | load a URL / search in an existing window, wait for the load |
| `get_page_content` | title, URL and `innerText` of a window (waits for loading; `max_chars`, default 20 000) |
| `get_page_links` | `text — URL` lines of the page's links (`max_links`) |
| `summarize_page` | summary from the assistant's own model (⌘K's choice: on-device / PCC / Claude); `focus` narrows it |
| `focus_window` | switch to the window's profile and workspace and scroll to it |
| `move_window` | move a window to another workspace of its profile |
| `close_window` | close a window |
| `evaluate_javascript` | run a function body in the page — in the *page's* world, unlike every other tool ([architecture.md](architecture.md#page-side-scripts)); result back as JSON |
| `create_document` | a document window (Markdown in a column) — `title` or `markdown`, optional `workspace`, `profile`, `activate` → id |
| `write_document` | `mode`: `replace` the text, `append`, or `section` — replace the body of one `## heading` (added when missing); `document_id` defaults to the run's document in the on-screen workspace |
| `read_document` | the document's Markdown and its section list |
| `cite` | adds `[n]: url "title" — retrieved …` (+ the passage) to the document's `## Sources` and returns `[n]`; from a window, a `url`, or a `highlight_id` (then the URL carries the `#:~:text=` fragment) |
| `highlight_page` | marks the paragraphs that answer `question` — the ⌘K model (on-device when ⌘K is an agent) picks *numbers* from `list_page_blocks`, six anchors them — or `blocks` given by hand; returns id, text and a text-fragment link per passage — see [deep-research.md](deep-research.md#highlighted-passages) |
| `list_page_blocks` `list_highlights` `remove_highlight` | the numbered paragraphs of a page; the highlights stored for a page; delete one |
| `list_bookmarks` `search_bookmarks` `read_bookmark` `add_bookmark` `refresh_bookmark` `remove_bookmark` | the profile's (or every profile's) saved pages, searched by meaning — see [bookmarks.md](bookmarks.md) |

Errors that are the caller's (unknown window, bad workspace, no model) come back as MCP tool errors (`isError`),
not JSON-RPC errors.

The catalog's instructions tell an agent what the strip is for: search first, then open the several pages actually
worth putting side by side — different sites, or the same site on the different options — each on the exact page for
what was asked. Asking for flights from Novosibirsk to Kazakhstan should leave a strip of route pages open, not one
front page. Reading a page (`get_page_content`) is for the answer the agent writes; the windows are what the user is
left with.

## Search

`web_search` (`six/Browser/WebSearch.swift`) fetches results the way the browser would: a `WebPage` of its own, off
screen, with a non-persistent data store — no window, no profile, no cookies of yours. The source is DuckDuckGo's
HTML endpoint, the no-JavaScript result page, whose markup (`.result__a`, `.result__snippet`) has been stable for
years and needs no API key; its links go through a redirector, so the real URL is unwrapped from `uddg`. If that
answers with nothing — a challenge page, a layout change — the ordinary result page is tried next and read through
its result blocks. The request carries the system's `Accept-Language`, so results come back in the language the user
reads. The engine chip on the start page is about the human's searches; this tool is DuckDuckGo either way.

## Trying it by hand

```sh
six=/path/to/six.app/Contents/MacOS/six
$six --mcp   # then paste, one line each:
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"me","version":"0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_window","arguments":{"url":"example.com","workspace":"Research"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_page_content","arguments":{}}}
```

Or register it with any MCP client, e.g. Claude Code: `claude mcp add six -- /path/to/six.app/Contents/MacOS/six --mcp`.

## Notes

- Any local process running as the user can connect to the socket; there is no authentication beyond file
  permissions. Agents still go through their own permission prompts before calling a tool.
- `JSONRPCConnection` reads lines on a thread of its own (`LineReader`) rather than through `FileHandle.bytes`:
  Foundation serves every `AsyncBytes` in the process from one serial I/O actor with blocking reads, so with the
  agent's pipe open the MCP socket never got a turn and the agent hung waiting for `initialize`.
- The protocol is small enough that it is implemented directly on `JSONRPCConnection` rather than through the
  official `modelcontextprotocol/swift-sdk` — a SwiftPM dependency would also build against Xcode's stale SDK
  (see [build](build.md)). Swapping it in later only touches `MCPServer.handle`.
