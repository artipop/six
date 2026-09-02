# MCP apps

An MCP server can return not only text but an **interface**: a ready page the
host shows instead of a tool result and then talks to. In a chat that becomes a
picture inside the conversation. Here an app is **a window on the rail**, level
with a website: it can be moved, carried to another workspace, left open and come
back to tomorrow.

It cost VI nothing: every window already has its own content process and its own
storage, which is a stronger sandbox than an iframe.

## The Apps menu

| | |
|---|---|
| **Manage Servers…** | opens `six://apps`, the built-in page listing the servers |
| the list of servers | a click runs that server's first tool with an interface |
| **Give to the Agent ▸ …** | hand a server's tools to the [agent](/en/agents) — then it opens such windows itself |

The list of servers is not a sheet but **a page on the rail**: it stands next to
the app it is about and survives a relaunch. Its address is shown in full, scheme
and all: `apps` without `six://` would read as somebody's domain.

## Where apps come from

There are many catalogues of MCP servers and not one catalogue of the servers
that draw something — the registry schema has no field to filter on. The only way
to know is to connect and look, so **VI builds that list itself**: it walks the
official registry, asks every remote server, and writes down the ones that have
an interface.

> The first full sweep, 30 August 2026: 25,772 servers in the registry, 13,555
> with an HTTP endpoint, all of them asked, an interface found in **308** — and
> 1,374 tools in them that draw a window.

The upper list in the panel is that one, ready. The search below it goes to the
registry live, for whatever the sweep did not reach.

Package servers (`npx`, `uvx`) are **not run** during the sweep: downloading and
executing somebody's code to find out what it does is not what the person who
opened the panel signed up for.

## Signing in

The panel probes remote servers without authorization — so that a search never
opens a sign-in window for anybody — and reports what it found: "39 of 39 draw a
window", "sign-in required", "did not answer".

The **Sign In** button appears only for a server that refused without a token,
and for nobody else: offered to everyone, it would stop meaning anything. Signing
in by hand is always possible through the row's context menu. A local server is
never asked: it is a process the browser started itself.

## Your own servers

**Add Server…** takes either a local command (run in your shell's environment, so
nvm and homebrew work) or an HTTP address. A token, if one is needed, is sent as
a bearer.

## When an app calls a tool

An app inside a window can ask the browser to run a tool of its server. That is
put to a person — a bar above the column — and the answer is remembered for the
life of the window.

A tool the server has not declared safe to repeat is never re-run by VI on its
own.

## What is given to the agent

A shared server's tools reach the agent as **the browser's own**, and then the
agent opens app windows itself: ask about the weather and get a weather window in
the rail rather than a paragraph. The agent's tool list is live: share a server
or take it back, and it finds out at once.

App windows are visible to the agent like pages: it can list them, read them and
take a screenshot of them.
