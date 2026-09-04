# Profiles and private windows

A profile is a separate person behind one browser: its own cookies and sign-ins,
its own history, its own bookmarks, its own extensions and **its own stack of
workspaces**. Switching profiles swaps the whole rail.

The profile button is on the left of the top bar, with its name and colour. A
click opens the list:

- a click on a row switches to that profile;
- unfolding a row renames it, picks its colour, deletes it;
- **New Profile** at the bottom;
- **New Private Window**, when there is no private profile yet.

Renaming a profile moves its folder on disk with it, so nothing saved under the
old name is orphaned.

## What a profile owns

| | |
|---|---|
| cookies, local storage, caches | an isolated WebKit data store |
| history | its own; `⌘Y` shows the current profile's |
| bookmarks | its own `Profiles/<name>/Bookmarks/` folder |
| workspaces | its own stack |
| extensions | its own controller and storage |
| the agents' working directory | `Profiles/<name>/Scratchpad` by default |

Blocking, certificates and filter lists are shared: they are what the **browser**
trusts and blocks, not what the person sitting in it does.

## Moving a window to another profile

Right-click the page ▸ **This Window ▸ Move to Profile** ▸ the profile's name. On
the phone the same item is in the `⋯` menu.

The window goes to the other profile's rail and the rail follows it there: this
is the one move that would otherwise leave nothing to look at — the column would
simply be gone from the rail. It is the same window and not a copy: the same
address, the same title, the same back and forward history, the same picture in
the overview. `⌘⇧T` will not offer it back, because nothing was closed.

The page does load again, though, and with **somebody else's cookies**. That is
the whole point: the same link, shown by a different person behind this browser.

| | |
|---|---|
| cookies and sign-ins | the profile it went to — usually another account, or a signed-out page |
| extensions | the new profile's |
| history | the visit is recorded in the new profile from the moment it lands; what the old one already wrote stays |
| highlights | every profile has its own: the old ones go, the new profile's appear |
| filled-in forms, unsent input | lost — the page loads from scratch |

A window moves out of a private profile the same way — and from that moment the
page is in the history of the profile it arrived in. That is exactly what asking
for it in a profile that keeps history means.

The workspace the window left asks nothing, even when that was its last window
and it has a name: nothing was closed. The named empty row stays standing — its
own context menu deletes it.

A document cannot be moved into a private profile, and the item is disabled: the
document's text is a file on disk, rewritten a second after every keystroke, and
a private profile is the one written down nowhere. The browser will not delete a
person's file to keep that promise.

## A private window

`⌘⇧P`, or **File ▸ New Private Window**.

Private browsing here is a profile, not a mode: the first press creates a private
profile, every one after it adds a window to it. The windows share one session,
the way Safari's private windows do.

What is *not* done:

- the site data store lives in memory and goes with the profile — cookies, local
  storage, IndexedDB, caches, service workers;
- no history is written;
- no bookmarks: the star and `⌘D` are disabled;
- no highlights are stored;
- documents are not written to disk and live in memory;
- the profile is not in the session snapshot — after a relaunch it is gone;
- extensions do not run in a private window at all: private browsing is recorded
  nowhere, and an extension's storage is a record.

**File ▸ Close Private Browsing** (or the profile chip's context menu) closes the
windows and forgets the profile. Quitting does the same.

The one file a private profile can still touch is its agent scratchpad, if an
agent is asked to work there.

## History

`⌘Y` is the current profile's history: search by title and address, `↑` `↓` walk
the rows, `↩` opens the selected visit in a new window, `⌘⌫` forgets it. The
**History** menu lists the last twenty pages separately.

**History ▸ Clear `<profile>` History…** asks what exactly to clear:

| | |
|---|---|
| **Clear History Only** | the list of visits |
| **Clear History and Site Data** | and the profile's cookies, local storage and caches |

The second signs you out everywhere in that profile, and its open pages reload.
The dialog says so.
