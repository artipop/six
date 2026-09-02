# Profiles and private windows

A profile is a separate person behind one browser: its own cookies and sign-ins,
its own history, its own bookmarks, its own extensions and **its own stack of
workspaces**. Switching profiles swaps the whole strip.

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
the rows, `↩` opens the selected visit in a new window, `⌫` forgets it. The
**History** menu lists the last twenty pages separately.

**History ▸ Clear `<profile>` History…** asks what exactly to clear:

| | |
|---|---|
| **Clear History Only** | the list of visits |
| **Clear History and Site Data** | and the profile's cookies, local storage and caches |

The second signs you out everywhere in that profile, and its open pages reload.
The dialog says so.
