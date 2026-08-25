# Agents (⌘⇧A)

`six/ACP/` is a self-contained Swift client for the [Agent Client Protocol](https://agentclientprotocol.com): JSON-RPC
over stdio to an adapter process.

- `JSONRPCConnection` — framing and request/response correlation over the pipes.
- `ACPAgent` — the adapter process (launch definition, environment, lifecycle).
- `ACPClient` — an actor speaking `initialize`, `session/new`, `session/prompt`, `session/cancel`, `session/set_mode`;
  it receives streaming `session/update` notifications and serves `session/request_permission` and
  `fs/read_text_file` / `fs/write_text_file` back to the agent, restricted to the session cwd.
- `AgentSessionStore` — the view model: transcript items, plans, permission prompts, working directory, model override.

## Toolchain

Adapters are npm packages, resolved through the user's login shell by `AgentToolchain`:

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
