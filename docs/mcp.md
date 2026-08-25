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
| `open_window` | `url` or `query` (search); optional `workspace`, `profile`, `activate` (false = add in the background, nothing on screen moves) |
| `navigate` | load a URL / search in an existing window, wait for the load |
| `get_page_content` | title, URL and `innerText` of a window (waits for loading; `max_chars`, default 20 000) |
| `get_page_links` | `text — URL` lines of the page's links (`max_links`) |
| `summarize_page` | summary from the assistant's own model (⌘K's choice: on-device / PCC / Claude); `focus` narrows it |
| `focus_window` | switch to the window's profile and workspace and scroll to it |
| `move_window` | move a window to another workspace of its profile |
| `close_window` | close a window |
| `evaluate_javascript` | run a function body in the page, result back as JSON |

Errors that are the caller's (unknown window, bad workspace, no model) come back as MCP tool errors (`isError`),
not JSON-RPC errors.

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
