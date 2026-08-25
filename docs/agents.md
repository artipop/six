# Agents (⌘⇧A)

`six/ACP/` is a self-contained Swift client for the [Agent Client Protocol](https://agentclientprotocol.com): JSON-RPC
over stdio to an adapter process.

- `JSONRPCConnection` — framing and request/response correlation over the pipes.
- `ACPAgent` — the adapter process (launch definition, environment, lifecycle).
- `ACPClient` — an actor speaking `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/set_mode`;
  it receives streaming `session/update` notifications and serves `session/request_permission` and
  `fs/read_text_file` / `fs/write_text_file` back to the agent, restricted to the session cwd.
- `AgentSessionStore` — the view model: transcript items, plans, permission prompts, working directory, model override.
  `session/new` also hands the agent the browser itself as an MCP server (`six --mcp`, see [mcp](mcp.md)), so it can
  open windows, read and summarize pages.

## Working directory

Each profile has a folder of its own — `~/Library/Application Support/six/Profiles/<name>`, created on first use —
and that is where the agent works by default. The panel only says "*Personal* folder" then; **Choose…** picks another
directory, which is stored on the profile (`Profile.workingDirectoryPath`), shown in full, and can be dropped with ⓧ
to go back to the profile's own folder. Switching profiles switches the folder; the next prompt reconnects the agent
with the new `cwd`.

## Debugging

`SIX_ACP_TRACE=1` mirrors the connection steps and every JSON-RPC line to stderr. `SIX_ACP_SELFTEST="hi"` opens the
panel and sends the text on launch; `SIX_ASSISTANT_SELFTEST="acp:claude-code:hi"` does the same through the ⌘K line
with the given model choice — together they exercise the whole path without clicking:

```sh
SIX_ACP_TRACE=1 SIX_ACP_SELFTEST="Say hi" ./six.app/Contents/MacOS/six 2>&1 | grep '^\[acp'
```

## Toolchain

Adapters are npm packages, resolved by `AgentToolchain` in the environment of an interactive login shell (`zsh -l -i`, so `.zshrc` — where nvm usually lives — counts):

- adapter on `PATH` (`claude-agent-acp` / `codex-acp`) → used directly;
- only `npm` → **Install** runs `npm install -g <adapter>`; until then the agent starts via `npx -y`;
- no Node.js → the panel links to the download page;
- the underlying CLI (`claude` / `codex`) must be installed and logged in — the panel warns if it isn't.

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
