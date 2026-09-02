# The strip and workspaces

There are no tabs and no sidebar. There is a **window** — a full-height page — a
**strip**, in which windows stand left to right, and a **workspace**, which is
one strip. Workspaces are stacked vertically; exactly one is on screen.

```
workspace "Tickets"   [ document ] [ aviasales ] [ tutu.ru ] [ s7.ru ]  →
workspace "Mail"      [ gmail ] [ calendar ]                           →
workspace 3           (empty — there is always one at the bottom)
```

A window is almost the width of the screen: the neighbours peek in at both edges,
so it is clear that they are there and which way to scroll. There is one width:
a window cannot be given half or two thirds of the screen, and that is a decision
rather than an omission — a page at two thirds of a screen is a page with a hole
beside it.

## With the keyboard

`⌥` stands in for niri's `Mod`. All of this is the **Layout** menu.

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window along the strip |
| `⌥Home` `⌥End` | first / last window in the strip |
| `⌥↑` `⌥↓` | workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below and follow it |
| `⌥W` | full window |
| `⌥⇧F` | fullscreen (`Esc` to leave) |
| `⌥O` | overview (`Esc` to leave) |
| `⌥C` | centre the focused window; off means the strip moves as little as it can |

## With the mouse alone

Nothing needs the keyboard: every operation has a mouse equivalent.

**A click on a background window** focuses it and pulls it to the middle. The
first click on somebody else's window never reaches the page — it is about the
window, not about what is drawn on it.

**The gaps beside the focused window.** Nothing is drawn there at rest. Sweep the
pointer in and the strip leans that way to show what is over there: a `‹` or a
`›` if it is a window, and an **outline of a window that does not exist yet** if
the strip has run out. A click on that sliver steps to the neighbour or opens a
new window — including one *before* the first, which is the only way the strip
grows backwards.

The sliver is as narrow as the gap it stands in and reaches the very edge of the
screen: throwing the pointer against the wall finds it.

::: tip View ▸ Peek at the Edges
The lean is a pointer idea: it is asked for by resting somewhere and waiting.
Turn the switch off and the arrows are simply drawn where they stand and work
without being hovered. It is on for macOS and always off on a phone.
:::

**Scrolling** over a gap, over the background or over the layout's own chrome
drives the strip: sideways by a window, up and down by a workspace. Over the page
itself, scrolling stays the page's. Over the top bar it does nothing — clicking
one of its buttons would be a gamble otherwise.

With `⌥` held the gestures work anywhere, the page included:

| | |
|---|---|
| `⌥` + vertical scroll | one workspace per gesture. Below the threshold the next one rubber-bands into view; once the switch commits, the rest of the gesture (trackpad momentum included) is swallowed, so a flick never skips two |
| `⌥` + horizontal scroll | one window per gesture while centring is on; with `⌥C` off, free panning |

**Right-click the background** — a new window, workspaces, the overview,
centring. **Right-click a page ▸ This Window** — close, full window, fullscreen,
move left/right, move to the workspace above/below.

**The layout button** on the left of the top bar: a click fills the window and
unfills it, holding it opens the list — the three ways of showing a window, the
overview, centring, and the moves for the focused window.

**The workspace stepper** on the right: `⌃`/`⌄` step one workspace up and down, a
click on a pip jumps to it.

## Three ways to show a window

Each one takes away more of what is not the page.

| | | |
|---|---|---|
| — | **the strip** | the ordinary one: the window is the screen less its outer gaps, in a card with corners |
| `⌥W` | **full window** | the page fills the window under the top bar: no gaps, no card, no corners |
| `⌥⇧F` | **fullscreen** | the top bar goes too; a bar with the steps, workspaces, overview and the way out hides at the top edge |

This is a mode of the application, not a property of a window: `⌥←` `⌥→` go on
walking the strip, and the next window arrives filled as well — a workspace reads
like a stack of pages.

Switching is deliberately **not animated**, unlike everything else in the layout:
every switch resizes every live page, and a page changing size costs a visible
hitch. Better to get it over with than to spread it across a third of a second.

Leaving: the same key, the menu, the layout button, and for fullscreen also `Esc`
and the bar's own button. `Esc` deliberately does **not** leave full window: that
is ordinary reading, where a page's own `Esc` is worth more. `⌘L` leaves either —
the address bar is exactly what they hide.

::: warning Three different "fullscreens"
This one (a layout mode), macOS fullscreen via the green button (the strip simply
fills a bigger window), and a video player's own fullscreen. They are three
different things, and `Esc` inside a video belongs to the video.
:::

## The overview

`⌥O` zooms the whole canvas out: workspaces open up and read as separate screens.
The scale picks itself — just enough to show the focused strip end to end; a short
one is not shrunk for nothing, and a very long one starts scrolling rather than
turning microscopic.

In the overview:

- scrolling sideways runs along the strip, up and down goes through workspaces;
- a click on a window opens it and closes the overview;
- **dragging** carries a window along its strip or onto another workspace —
  including the empty one at the bottom, which is how a new workspace is made.
  The focus goes with the window: a window put in another row while the view
  stayed in the old one is a window you have just lost;
- **a double-click on a workspace's name** renames it; a right-click renames or
  clears it.

Nothing loads in the overview: every window there is a card, and a card is the
last picture of its page.

## Workspaces make themselves

There is always exactly one empty workspace at the bottom. Move a window into it
and a fresh empty one appears below. A workspace that runs out of windows
disappears — unless you gave it a name. **A named workspace survives being
empty**, and that is the only way to book a place for a job in advance.

## How many pages are actually live

A page is a process of its own: its own memory, its own timers, its own
rendering. A strip of a hundred windows cannot carry a hundred of them, so VI
does what Chrome's Memory Saver and Safari's suspended tabs do: it **discards**
the pages it is unlikely to be asked for and builds them again from the address.

Discarding is not closing. The window stays where it is, with its address, its
title, its back/forward history, its scroll offset and a picture of itself, and
builds its page again when you come back to it.

- There is one queue for the whole application — every profile, every workspace.
  That is why stepping out to another workspace and back finds the pages still
  warm.
- A page is built **once the focus has settled**, not on the way: hold `⌥→`
  across ten windows and you load one, the one you stopped at.
- Nothing that is loading, playing audio or video, holding a draft in a text
  field or a filled-in password is discarded.
- **Layout ▸ Keep Loaded** sets the budget; by default it is sized from the
  machine's memory. **Unload Background Windows** does it right now.
- Under memory pressure the budget shrinks on its own and grows back when the
  pressure lifts.

There is no "blocked" counter here for the same reason there is none in blocking:
the number would have to be invented.
