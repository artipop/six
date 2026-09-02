# Settings

`⌘,` — or the address `six://settings`, typed into the field.

Settings here are a **page**, not a window of their own. It opens as a column of
the rail, beside the thing it is about: you can look at a site and read what that
site is allowed at the same time — a settings window would cover exactly what it
describes. The column keeps its place across a relaunch, it has an address, and
it moves and closes like any other window.

::: tip Where this came from
VI used to have thirteen menus, five of them one feature each with a switch
inside — the kind you set once and forget. A switch is not a command: it has no
key, it does not answer "what can I do here", and there is no guessing which of
five menus it filed itself under. All of that moved here, and what stayed in the
menus is what a menu is for: things you do, with a key beside them.
:::

## General

**Search engine** — DuckDuckGo or Google. The same choice is the chip on the left
of the field on the start page.

**Translation** — the language pages are translated into (`⌘⇧L`). The list is
whichever languages macOS has a model for.

**Bookmarks** — what the assistant searches (this profile or all of them) and how
often a saved page is re-read from its site. Also how many are saved in this
profile, and a button to re-read them all now.

**Default browser** — hand VI the links from other applications. A development
build never offers: it is a second application wearing the same face, and links
from the whole machine would go into a browser that is about to be killed and
built again.

## Windows

**Centre the focused window** (`⌥C`) — the window you are reading sits in the
middle and both neighbours peek in by the same amount. Off, the rail moves as
little as it can.

**Peek at the edges** — the rail leaning over when the pointer rests in a gap.
That is a pointer idea: it is asked for by resting somewhere. A finger has
nowhere to rest, so the switch is off on the phone and the arrows are simply
drawn where they stand.

**Loaded windows** — how many windows are holding a live page right now, and a
button to unload the background ones. The number cannot be changed: how many
separate processes a particular Mac will carry is not a thing a person can know,
so VI works it out from the machine's memory and adjusts as the pressure moves.

## Privacy

Three tabs, and each of them used to be a window of its own.

**Blocking** — the switch, the filter lists (how many rules in each, when it last
updated) and the sites you asked it to leave alone. The shield in the address
field opens the same screen. More in [Ads and trackers](/en/blocking).

**Site permissions** — every site you have answered about the camera, the
microphone or the motion sensors, with a switch for each. More in
[Site permissions](/en/permissions).

**Certificates** — the certificate authorities VI trusts on top of the system's.
Everything starts off. More in [Certificates](/en/certificates).

## Assistant

Which model answers `⌘K` and which agent answers the `⌘⇧A` panel, how many
sources deep research takes, and the keys and addresses for Claude and for any
server speaking the OpenAI format. More in [The assistant](/en/assistant) and
[Agents](/en/agents).

::: warning The keys are stored locally
This is a development shape: the keys sit in `UserDefaults`, not the Keychain.
:::

## Extensions

What is installed, what each one can do here, and installing from a folder, a
`.zip`, a `.crx` or an `.xpi`. More in [Extensions](/en/extensions).

## Develop

Let Safari's inspector attach to VI's pages, and capture the console and the
network — not for a person, but for the agent's tools. More in
[Developer tools](/en/devtools).

## Where it all lives

Every setting is a row in the `settings` table of VI's database, beside the
history and the bookmarks, rather than in `UserDefaults`. So they travel with the
rest of the profile's data, and one day they will be able to sync.
