# Configuration

`⌘,` — or the address `savoia://configuration`, typed into the field.

Every section has an address of its own: `savoia://configuration/assistant`,
`/privacy`, `/windows`, `/extensions`, `/develop`. Privacy and Assistant hold
tabs inside them, and those are anchors on that page, after a `#`:
`/privacy#blocking`, `/privacy#sites`, `/privacy#certificates`,
`/assistant#responses`, `/assistant#agents`, `/assistant#mcp` — so **Site
Permissions…** in a window's permission menu arrives at the permissions rather
than at the filter lists. Buttons like **Set Up…** in the
`⌘E` line open the section they mean rather than the top of the page, and the
address follows you as you move between sections.

Configuration here is a **page**, not a window of its own. It opens as a tab, it
has an address, it keeps its place across a relaunch, and it can stand beside a
site and close like any other tab.

::: tip Where this came from
Savoia used to have thirteen menus, five of them one feature each with a switch
inside — the kind you set once and forget. A switch is not a command: it has no
key, it does not answer "what can I do here", and there is no guessing which of
five menus it filed itself under. All of that moved here, and what stayed in the
menus is what a menu is for: things you do, with a key beside them.
:::

## General

**Search engine** — DuckDuckGo, Google, Bing or Yandex. The same choice is the
chip on the left of the field on the start page.

**Start page** — what stands above the field: the **Name** (which can be
changed), the app's **Icon**, or **None**.

**Translation** — the language pages are translated into (`⌘⇧L`). The list is
whichever languages macOS has a model for.

**Bookmarks** — what the assistant searches (this profile or all of them) and how
often a saved page is re-read from its site. Also how many are saved in this
profile, and a button to re-read them all now.

**Default browser** — hand Savoia the links from other applications. A development
build never offers: it is a second application wearing the same face, and links
from the whole machine would go into a browser that is about to be killed and
built again.

## Tabs

**Group Tabs by Meaning** — a new tab goes into the group it is about by itself,
and three alike tabs with no group become a group. **Sort By** and **Local
Model** are there too. More in [Groups by meaning](tabs.md#groups-by-meaning).

**Old Tabs ▸ Offer to Close** — how often to offer closing tabs not opened for a
long time whose topic you no longer come across, and **Look Now**. More in [Old
tabs](tabs.md#old-tabs).

**Loaded Tabs** — how many tabs are holding a live page right now, and **Free
Memory**. The number cannot be changed: how many separate processes a particular
Mac will carry is not a thing a person can know, so Savoia works it out from the
machine's memory and adjusts as the pressure moves.

## Privacy

Three tabs, and each of them used to be a window of its own.

**Blocking** — the switch, the filter lists (how many rules in each, when it last
updated) and the sites you asked it to leave alone. The shield in the address
field opens the same screen. More in [Ads and trackers](/en/blocking).

**Site permissions** — every site you have answered about the camera, the
microphone or the motion sensors, with a switch for each. More in
[Site permissions](/en/permissions).

**Certificates** — the certificate authorities Savoia trusts on top of the system's.
Everything starts off. More in [Certificates](/en/certificates).

## Assistant

Three tabs:

- **Responses** — who answers `⌘E`, the model and API credentials. Agent model lists come from the agent itself. **Access to Page Console and Network** also lives here.
- **Agents** — install or update Claude Code and Codex, add or edit other ACP agents using their launch command. Once a tool call has been answered "always", **Ask Again** lives here too.
- **MCP** — connected servers with addresses, status and Agent Access switches. Each server’s “…” menu contains editing, connection checks, sign-in, opening apps and removal. Adding a server and browsing the MCP catalogue open separately.

Deep research settings have been removed from this page. More in [The assistant](/en/assistant), [Agents](/en/agents) and [MCP apps](/en/apps).

::: warning The keys are stored locally
This is a development shape: the keys sit in `UserDefaults`, not the Keychain.
:::

## Extensions

What is installed, what each one can do here, and installing from a folder, a
`.zip`, a `.crx` or an `.xpi`. More in [Extensions](/en/extensions).

## Develop

Let Safari's inspector attach to Savoia's pages and open the browser log. More in
[Developer tools](/en/devtools).

## Where it all lives

Every setting is a row in the `settings` table of Savoia's database, beside the
history and the bookmarks, rather than in `UserDefaults`. So they travel with the
rest of the profile's data, and one day they will be able to sync.
