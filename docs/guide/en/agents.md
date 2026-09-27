# Agents

An agent here is Claude Code, Codex or another agent that speaks ACP, running on
your machine and able to **drive the browser**: open windows into a named
workspace, read pages, summarize them, move and close windows.

You talk to an agent through the [`⌘E`](/en/assistant) line: choose it instead
of a language model, and it is the one that answers there. Every conversation
with an agent is kept, and they are all on the [**Chats**](#chats) page.

The conversation goes over ACP (the Agent Client Protocol), the same protocol
those agents speak to editors. VI hands the agent itself as an MCP server, so the
browser's tools appear in the agent's hands on their own.

## Choosing an agent

- **Configuration ▸ Assistant ▸ ⌘E Line**, the **Assistant** list: Claude Code,
  Codex or an agent you added. Under it, the **Model** the agent answers with;
  the agent supplies the list, and the choice is kept per agent.
- Or on the line itself: the icon left of the field opens a menu with the same
  agents and their models.

On the first launch the same is asked on the **Welcome** page.

## What has to be installed

All of it is on the **Configuration ▸ Assistant ▸ Agents** tab. Claude Code and
Codex each have a section there: the **adapter's** version and, separately, the
version of `claude` or `codex` itself — two different numbers, since an adapter
carries its own copy of the CLI. The **Install** and **Update** buttons are there
too, with how to log in and the **Copy Command** and **Open Terminal** buttons.

It checks your shell's environment:

| | |
|---|---|
| the adapter is on `PATH` | used directly, with its version beside the name |
| a newer one is out | the row says so, with an **Update** button |
| only `npm` is there | **Install** puts the adapter in globally; until then it starts through `npx` |
| no Node.js | a link to the download page |
| no `claude` / `codex` itself | the section warns, and says how to install it and log in |

It checks an interactive login shell, so nvm and homebrew from `.zshrc` count.
The `⌘E` line checks nothing about an agent in advance: if it fails to start, the
reason arrives in place of the answer.

**Add Agent…** connects any other ACP agent: a name, an executable and its
arguments, one per line. **Edit…** and **Remove** are in its section.

## What it looks like

An agent's answer arrives in the card above the line like any other. While it
works, the tool it is using is named next to the model — readably: `six
open_window`, the server, a space, the method. A title the agent wrote itself
(`Read`, `Bash`, a whole sentence) is left alone.

When the agent asks for permission, the buttons appear inside the answer card.
Until you answer, it waits. Under the tool's name are its arguments, one row
each: name and value.

An "always" answer (allow or reject) is remembered for that agent and that tool —
across a model switch and a relaunch of VI. That call never asks again. How many
of them there are is on the **Agents** tab under **Tool Calls**; **Ask Again**
forgets them all.

## Where the agent works

In the profile's scratchpad folder (`Profiles/<name>/Scratchpad`): every profile
has its own, and switching profiles switches the folder — the next question
reconnects the agent to the new one.

The scratchpad is deliberately **not** the bookmarks folder: a question about a
saved page should go through search by meaning, not through a crawl of the
files next to it.

## Conversations on the ⌘E line

Every time the line is called up it starts a new conversation; follow-ups asked
while it stays open go into the same one. **New Conversation** in the line's
menu starts a new one without closing it.

To go back to an older conversation, type `/` and a word of its title into the
line: matching chats appear under the verbs (a bare `/` shows the five latest).
`↑` `↓` walk them and `↩` picks one. The chosen chat stands in the line as a
chip, its last question and answer above it, and the next question continues
that conversation — with the agent it was had with. ↗ on the chip opens the chat
as a window; clicking the chip or `⌘⌫` goes back to a new conversation.

The agent remembers a conversation across a relaunch of VI: the session goes on
where it stopped. When the agent cannot do that, or has lost the session, a new
one starts and the saved transcript stays above it as a record.

## Chats

Every conversation with an agent is on the **Chats** page (`⌘⇧E`, or View ▸
Chats). It is not a sidebar but a column of the row like any other page: it
opens beside what you are doing and closes when you have found what you wanted.
Chats are grouped by day; the search looks through their titles, and **All
folders** shows the ones from other folders too. **New Chat** opens an empty
one.

A chat opens as a window of its own to the right, so two can stand side by
side. Write in it and it becomes its agent's current chat, and VI asks the agent
to resume the same session. A chat from another folder can be read but not
continued. Right-click a chat for **Delete**; the agent keeps its session.

Below, **Other sessions** lists what the agents themselves remember about the
folder — sessions started from Claude Code's or Codex's own command line, say.
Each one says which agent it was with. Open one and press **Load from the
Agent**, and the agent sends its history over.

## What an agent can do in the browser

The vocabulary is the product's: a **window** (page) in a **workspace** (row)
of a **profile**. Everything defaults to what is on screen.

| | |
|---|---|
| look | list workspaces and windows, read a page's text, its links, summarize it |
| open | search the web; open a window by address or by query — including **behind**, so nothing on screen moves; open a private window |
| move | focus a window, move it to another workspace, close it |
| act | a snapshot of the page with its buttons and fields numbered, click, fill a field, choose an option in a list, press a key, scroll, wait for a result — this is how an agent fills in forms and searches for flights by itself |
| debug | what a page logged, what it requested, a screenshot, run code in the page |
| write | create a document, write into it section by section, cite a source, highlight the paragraphs that answer a question |
| bookmarks | list, search by meaning, read, add, refresh, remove |

The agent sees the console and the network only while **Configuration ▸ Assistant ▸ ⌘E Line ▸ Access to Page Console and Network** is on — see [developer tools](/en/devtools).

An agent acts in a real window and in your profile — where you are already signed in
to the sites. Every action shows in the panel, and the agent asks before each one. It is
told not to press anything that pays, books, sends or deletes: it stops, says what is
ready, and leaves the last button to you. The ⌘E line gets no actions at all.

## The same agent on the ⌘E line

The `⌘E` model menu has **Claude Code (ACP)** and **Codex (ACP)**. That is the
same session and the same transcript as the panel: permission requests appear
inside the answer card, and the tool the agent is using is named next to the
model.

## The browser as an MCP server for anything else

The same binary run as `six --mcp` is an MCP server over the running
application. Any MCP client can connect to it and drive the browser the way the
agent on the `⌘E` line does. For example:

```sh
claude mcp add six -- /Applications/six.app/Contents/MacOS/six --mcp
```

::: warning Who can connect
Any process running as your user can connect to the socket; there is no
authentication beyond the file's permissions. The agents themselves still ask
before calling a tool.
:::
