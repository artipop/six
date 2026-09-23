# Agents

The agent panel buttons and shortcut are temporarily disabled. An agent here is Claude Code or Codex, running on
your machine and able to **drive the browser**: open windows into a named
workspace, read pages, summarize them, move and close windows.

The conversation goes over ACP (the Agent Client Protocol), the same protocol
those agents speak to editors. VI hands the agent itself as an MCP server, so the
browser's tools appear in the agent's hands on their own.

## What has to be installed

The adapters live in **Configuration ▸ Assistant ▸ Adapters**, which shows the
**adapter's** version and, under it, the version of `claude` or `codex` itself —
two different numbers, since an adapter carries its own copy of the CLI — and
carries the **Install** and **Update** buttons. The panel says
nothing while all is well, and one line with a **Set Up…** button when it is
not.

It checks your shell's environment:

| | |
|---|---|
| the adapter is on `PATH` | used directly, with its version beside the name |
| a newer one is out | the row says so, with an **Update** button |
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

✎ in the panel header starts a new chat, and the old one goes to **Chats**.

### Chats

Every conversation — in the panel and on the `⌘E` line — is on the **Chats**
page (`⌘⇧E`, View ▸ Chats, or the clock in the panel header). It is not a
sidebar but a column of the rail like any other page: it opens beside what you
are doing and closes when you have found what you wanted. Chats are grouped by
day; the search looks through their titles, and **All folders** shows the ones
from other folders too.

A chat opens as a window of its own to the right, so two can stand side by
side. Write in it and it becomes its agent's current chat, and VI asks the agent
to resume the same session. A chat from another folder can be read but not
continued.

Below, **Other sessions** lists what the agents themselves remember about the
folder — sessions started from Claude Code's or Codex's own command line, say.
Each one says which agent it was with. Open one and press
**Load from the Agent**, and the agent sends its history over. Right-click a
chat for **Delete**; the agent keeps its session.

**Model** is selected in **Configuration ▸ Assistant ▸ Responses**. The selected agent supplies the list; preferences are saved per agent. No extra default option is inserted: an agent-provided `default` appears once.

**Add Agent…** connects another ACP agent: enter its name, executable and arguments, one per line. Then select the agent in Responses to have it answer through `⌘E`.

## What an agent can do in the browser

The vocabulary is the product's: a **window** (page) in a **workspace** (rail)
of a **profile**. Everything defaults to what is on screen.

| | |
|---|---|
| look | list workspaces and windows, read a page's text, its links, summarize it |
| open | search the web; open a window by address or by query — including **behind**, so nothing on screen moves; open a private window |
| move | focus a window, move it to another workspace, close it |
| debug | what a page logged, what it requested, a screenshot, run code in the page |
| write | create a document, write into it section by section, cite a source, highlight the paragraphs that answer a question |
| bookmarks | list, search by meaning, read, add, refresh, remove |

The agent sees the console and the network only while **Configuration ▸ Assistant ▸ Access to Page Console and Network** is on — see [developer tools](/en/devtools).

## The same agent on the ⌘E line

The `⌘E` model menu has **Claude Code (ACP)** and **Codex (ACP)**. Permission
requests appear inside the answer card, and the tool the agent is using is named
next to the model.

Every time the line is called up it starts a new chat; follow-ups asked while it
stays open go into the same one. The previous chat goes to **Chats**, and the
agent panel shows the new one.

To go back to an older chat, type `/` and a word of its title into the line:
matching chats appear under the verbs (a bare `/` shows the five latest). `↑`
`↓` walk them and `↩` picks one. Pick one and it stands in the line as a chip, the last question and answer above it,
and the next question continues that chat. ↗ on the chip opens the chat as a
window; clicking the chip or `⌘⌫` goes back to a new chat.

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
