# Agents (⌘⇧A)

`⌘⇧A` opens the agent panel. An agent here is Claude Code or Codex, running on
your machine and able to **drive the browser**: open windows into a named
workspace, read pages, summarize them, move and close windows.

The conversation goes over ACP (the Agent Client Protocol), the same protocol
those agents speak to editors. VI hands the agent itself as an MCP server, so the
browser's tools appear in the agent's hands on their own.

## What has to be installed

The panel checks your shell's environment and says what is missing:

| | |
|---|---|
| the adapter is on `PATH` | used directly |
| only `npm` is there | **Install** puts the adapter in globally; until then it starts through `npx` |
| no Node.js | a link to the download page |
| no `claude` / `codex` itself | the panel warns: *Install Claude Code and run `claude` once to log in* |

It checks an interactive login shell, so nvm and homebrew from `.zshrc` count.

## What it looks like

The panel carries the transcript: messages, plans, tool calls and permission
requests. A tool call is named readably — `six open_window`: the server, a space,
the method. A title the agent wrote itself (`Read`, `Bash`, a whole sentence) is
left alone.

When the agent asks for permission, buttons appear in the transcript. Until you
answer, it waits.

## Where the agent works

By default in the profile's scratchpad (`Profiles/<name>/Scratchpad`), and the
panel says so: *`<name>` scratchpad*. **Choose…** picks another directory; it is
stored on the profile, shown in full, and the `×` goes back to the scratchpad.

The scratchpad is deliberately **not** the bookmarks folder: a question about a
saved page should go through the search rather than through the files next door.

Switching profiles switches the folder; the next prompt reconnects the agent
there.

## Chats

A conversation belongs to an agent in a folder: switch the profile or the agent
and the chat on show switches too. Chats are saved with the rest of the session,
and on the next launch VI asks the agent to resume the previous one. When it
cannot, or the session is gone, a new one starts and the old transcript stays
above it as a record.

✎ in the panel header forgets the current chat and its session.

**Model override** in the panel is for when your `claude` default model is not
available through the SDK.

## What an agent can do in the browser

The vocabulary is the product's: a **window** (page) in a **workspace** (strip)
of a **profile**. Everything defaults to what is on screen.

| | |
|---|---|
| look | list workspaces and windows, read a page's text, its links, summarize it |
| open | search the web; open a window by address or by query — including **behind**, so nothing on screen moves; open a private window |
| move | focus a window, move it to another workspace, close it |
| debug | what a page logged, what it requested, a screenshot, run code in the page |
| write | create a document, write into it section by section, cite a source, highlight the paragraphs that answer a question |
| bookmarks | list, search by meaning, read, add, refresh, remove |

The two console-and-network lines need **Develop ▸ Capture Console and Network** —
see [developer tools](/en/devtools).

## The same agent on the ⌘K line

The `⌘K` model menu has **Claude Code (ACP)** and **Codex (ACP)**. That is the
same session and the same transcript as the panel: permission requests appear
inside the answer card, and the tool the agent is using is named next to the
model.

## The browser as an MCP server for anything else

The same binary run as `six --mcp` is an MCP server over the running
application. Any MCP client can connect to it and drive the browser the way the
panel does. For example:

```sh
claude mcp add six -- /Applications/six.app/Contents/MacOS/six --mcp
```

::: warning Who can connect
Any process running as your user can connect to the socket; there is no
authentication beyond the file's permissions. The agents themselves still ask
before calling a tool.
:::
