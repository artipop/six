# First launch

VI is a browser with no tabs. A page takes a whole window, windows stand in a row
and scroll sideways, and there are as many rows as you have jobs on. Everything
else is an ordinary browser: an address, history, bookmarks, downloads,
extensions.

The layout is taken from [niri](https://github.com/YaLTeR/niri), a window
manager for Linux. Three words describe it, and they are worth learning at once:

| | |
|---|---|
| **window** | one page. Not a tab: a window has no title bar, it *is* the page, edge to edge |
| **rail** | a row of windows running to the right. Scrolls endlessly |
| **workspace** | one whole rail. Workspaces stack up; exactly one is on screen |

The rail moves sideways, workspaces switch up and down. That is the whole of
the navigation.

## What is on screen

At the top, one row for the whole application, and it is about the window you
are reading: back and forward, the lock, the blocking shield, the address — and
right against the field, the bookmark star, because it is about that same page.
No individual window has a title bar of its own — a dozen windows in a rail do
not want a dozen address fields.

On the left of that row: the profile button, with its name and colour, and the
layout button. On the right: the workspace stepper, the overview, and the
download ring, which appears only once something has been downloaded.

The `×` that closes a window is the one thing that stayed with the window: it
sits on its top right corner and is invisible until the pointer is on it.

## A new window

`⌘T` opens one to the right of the current one. It opens not on somebody's home
page but on VI's own **start page**: one field that takes a query and an address
equally.

As you type, completions gather under it, in this order:

1. an **address row**, when what you typed looks like one (`apple.com`,
   `localhost:3000`, anything with a scheme), so that `↩` opens it rather than
   searching for it;
2. up to two **pages you saved**, found by meaning rather than by their titles;
3. up to four pages **from this profile's history**, by title and host, the
   often-visited ones first;
4. the search engine's own suggestions, each labelled with the engine — *DuckDuckGo
   Search*, *Google Search*, *Bing Search*, *Yandex Search* — so it is clear where
   `↩` goes.

Saved above visited above guessed: a bookmark is a page you decided to keep,
history is a page you happened to open, and a completion is what everybody else
is typing.

`↑` `↓` walk the rows, `↩` opens the selected one, `Esc` clears the field.

The engine is switched from the chip to the left of the field, or from
**Settings ▸ General ▸ Search Engine**; DuckDuckGo by default. The choice is shared by the
start page, the address bar and the assistant.

::: tip The query leaves the machine as you type
That is what a suggestion service is. VI sends them over a session of their own —
no cookies, no cache, nothing tied to a profile. Beyond that, the start page
touches the network not at all.
:::

## The personal half

The second row in that list is the one thing a search engine cannot have: your
own bookmarks, found [by meaning](/en/bookmarks#search-by-meaning). The same way
`⌘⌥B` finds them, and the same way **across languages** — «плов» finds the
English page about pilaf you once saved, "rate limiting" finds the article you
kept about it whatever language you ask in. All of it is worked out on your
machine; nothing goes anywhere.

Four things keep it out of the way:

- **with no bookmarks, nothing happens** — the query is not even worked out, and
  the model behind search-by-meaning is not downloaded because somebody typed in
  the field. An address is skipped too: a host is not a question;
- **nothing appears while you are still typing the first word**. An unfinished
  word is not yet a question: «руд», three letters into a word about mines,
  should not fetch a pilaf recipe merely for being the nearest thing to it;
- **two rows at most**, and they are not always there. Search by meaning answers
  anything — the nearest page is still the nearest page when nothing is near —
  so for a question about something you never saved, VI shows nothing rather than
  the closest thing it has;
- **a private window has none of it**: nothing is saved from there, and answering
  with your bookmarks in a window opened precisely to leave nothing behind would
  be the wrong thing.

::: tip What is honest to say about the quality
The order of the rows is nearly always right; the closeness *number* behind it is
not. For this model a question about something you never saved scores as high as
a real one, so on a whole phrase it does miss sometimes: one stray row under a
query that has nothing to do with what you kept. It is harmless — `↩` with
nothing selected still goes to the search engine.
:::

## The first ten minutes

The order worth trying:

1. `⌘T` three or four times, open something in each. That is a rail.
2. `⌥←` and `⌥→` walk along it. `⌥` stands in for niri's `Mod`.
3. `⌥↓` goes to the workspace below. It is empty; open something of your own
   there.
4. `⌥O` is the overview: everything at once, workspaces stacked. A click opens a
   window, a drag moves it, a double-click on a workspace's name renames it.
5. `⌥W` fills the window, gaps and all. Again to leave.
6. Sweep the pointer into the gap beside the focused window. The rail leans over
   to show what is there: `‹` or `›` if it is a window, an outline if there is no
   window there yet — and a click makes one.

None of this needs the keyboard:
[every operation has a mouse equivalent](/en/layout#with-the-mouse-alone).

## Where things are kept

All of it on your machine, in `~/Library/Application Support/org.deffun.six`:

| | |
|---|---|
| `state.json` | windows, strips, workspaces, agent chats — the session snapshot |
| `six.sqlite` | history, bookmarks, site permissions, settings |
| `Profiles/<name>/` | the profile's bookmarks as files, and the agents' scratchpad |
| `Blocking/`, `Models/`, `Thumbnails/`, `Screenshots/` | filter lists, the model behind search-by-meaning, window pictures, screenshots |

A session survives a relaunch whole: windows come back where they stood, with
their addresses and scroll offsets, and agent chats carry on.

## Making it the default browser

The **six ▸ Set six as Default Browser…** menu item, or System Settings › Desktop
& Dock › Default web browser. After that, links from other applications and
`.html` files from the Finder arrive as windows on the rail.
