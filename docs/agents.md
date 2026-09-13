# Agents

`six/ACP/` is a self-contained Swift client for the [Agent Client Protocol](https://agentclientprotocol.com): JSON-RPC
over stdio to an adapter process.

- `JSONRPCConnection` — framing and request/response correlation over the pipes.
- `ACPAgent` — the adapter process (launch definition, environment, lifecycle).
- `ACPClient` — an actor speaking `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/set_mode`;
  it receives streaming `session/update` notifications and serves `session/request_permission` and
  `fs/read_text_file` / `fs/write_text_file` back to the agent, restricted to the session cwd.
- `AgentSessionStore` — the view model: transcript items, plans, permission prompts, working directory, model override.
  `session/new` also hands the agent the browser itself as an MCP server (`six --mcp`, see [mcp](mcp.md)), so it can
  open windows, read and summarize pages. Through the same server it reaches the tools a page declares for agents
  (WebMCP — `list_page_tools`, `call_page_tool`) when `six://settings` ▸ Develop ▸ WebMCP is on; the catalog's
  instructions put them after a connected service's own tools and before reading the page, and fence everything a
  page says as its data rather than instructions ([webmcp.md](webmcp.md)).

## What a tool call is called

An agent namespaces the tools it got from an MCP server: Claude Code hands them to the model — and to us — as
`mcp__six__open_window`. That prefix is the client's own disambiguation, not the protocol's, so the panel takes it
apart before showing anything: `AgentToolName.display` drops `mcp__` and turns `__` into a space, leaving
**`six open_window`** — the server, then the method. The rewrite happens once, where the notification lands
(`AgentSessionStore.handle`, and the permission request beside it), so the transcript, the permission prompt, the
⌘E activity line and the saved chat all agree. Titles an agent wrote itself (`Read`, `Bash`, a whole sentence) pass
through untouched. See [mcp.md](mcp.md#names) for the naming on the wire.

## Working directory

Each profile has a folder of its own — `~/Library/Application Support/org.deffun.six/Profiles/<name>` — and the agent works in
its `Scratchpad/` by default, created on first use: a place for whatever a run writes, next to (not inside) the
profile's `Bookmarks/`, so saved pages are reached through the MCP tools and their search rather than by grepping the
working directory ([bookmarks.md](bookmarks.md)). The panel only says "*Personal* scratchpad" then; **Choose…** picks
another directory, which is stored on the profile (`Profile.workingDirectoryPath`), shown in full, and can be dropped
with ⓧ to go back to the scratchpad. Switching profiles switches the folder; the next prompt reconnects the agent
with the new `cwd`.

## Chats and sessions

A conversation belongs to an agent in a folder (`AgentChat`: agent id, directory, ACP session id, transcript), so
switching profile or agent switches the chat on show. Chats are saved with the rest of the app state (see
[architecture](architecture.md)). On the next connect the store asks the agent for `session/load` with the saved id
when it advertises `loadSession`; the agent replays the conversation as `session/update`s (`user_message_chunk`
included), which replace our copy of the transcript, and the agent remembers the context. When the agent can't load
sessions or the id is gone, a new session starts and the saved transcript stays above it as a record. ✎ in the panel
header forgets the current chat and its session.

## Debugging

`SIX_ACP_TRACE=1` mirrors the connection steps and every JSON-RPC line to stderr. `SIX_ACP_SELFTEST="hi"` opens the
panel and sends the text on launch; `SIX_ASSISTANT_SELFTEST="acp:claude-code:hi"` does the same through the ⌘E line
with the given model choice — together they exercise the whole path without clicking:

```sh
SIX_ACP_TRACE=1 SIX_ACP_SELFTEST="Say hi" ./six.app/Contents/MacOS/six 2>&1 | grep '^\[acp'
```

## Toolchain

Adapters are npm packages, resolved by `AgentToolchain` in the environment of an interactive login
shell (`zsh -l -i`, so `.zshrc` — where nvm usually lives — counts). They are **shown and installed on
`six://configuration` ▸ Assistant ▸ Agents** (`AgentToolchainSection`), not in the panel: installing
one is a setting, and the panel is where work happens. The panel keeps one line
(`AgentToolchainHint`) for when something is wrong — the adapter missing, behind, or the CLI not
found — with **Set Up…** to that page, and says nothing at all when everything is in order:

- adapter on `PATH` (`claude-agent-acp` / `codex-acp`) → used directly, with its version read from
  `<adapter> --version` and compared against `npm view <package> version`; when it is behind, the row
  says so and **Update** runs the install again. Both numbers are named and shown — **Adapter 1.12.0**
  over **codex 0.154.0** — because they are different numbers and reading one as the other is the
  whole of the fault below. (Each CLI answers `--version` its own way: `2.1.276 (Claude Code)`, or the
  package name and then the number, so the version is the first `1.2.3`-shaped word in the line.) A
  successful install clears its log — npm's lines about funding are not a report, and the version
  beside the name is;
- only `npm` → **Install** runs `npm install -g <adapter>@latest`; until then the agent starts via
  `npx -y <adapter>@latest`;
- no Node.js → the panel links to the download page;
- the underlying CLI (`claude` / `codex`) must be installed and logged in — the panel warns if it isn't.

**An adapter is not a shim, and this cost a session.** It carries its own copy of the CLI it drives:
`codex-acp` 1.1.14 depends on `@openai/codex` 0.147, so with Codex 0.154 installed and current on the
machine, six's agent still answered a request for today's model with `The 'gpt-6-astra' model requires
a newer version of Codex`. Nothing on screen said which of the two was old, and `npx -y <package>`
does not help: it reuses whatever version its cache holds, which here was a year of releases behind.
Hence `@latest` in both the npx arguments and the install command, and the version beside the
adapter's name in the panel.

Manual smoke test:

```sh
npm install -g @agentclientprotocol/claude-agent-acp
claude-agent-acp   # then paste, one line each:
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true}}}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"<id from above>","prompt":[{"type":"text","text":"hi"}]}}
```

Claude Code refuses to run nested inside another Claude Code session, so `CLAUDECODE` is stripped from the agent
environment. If your default `claude` model isn't available through the SDK, set "Model override" in the panel — it is
exported as `ANTHROPIC_MODEL`.
