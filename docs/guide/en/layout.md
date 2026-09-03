# The rail and workspaces

There are no tabs and no sidebar. There is a **window** — a full-height page — a
**rail**, on which windows stand left to right, and a **workspace**, which is
one rail. Workspaces are stacked vertically; exactly one is on screen.

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

`⌥` stands in for niri's `Mod`. There is no **Layout** menu for these any more: the keys are read
before the page is, so they answer even with the cursor inside a page — which is exactly what a menu
could not do. `⌥` and an arrow stays word movement while the caret is in a text field.

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window along the rail |
| `⌥Home` `⌥End` | first / last window on the rail |
| `⌥↑` `⌥↓` | workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below and follow it |
| `⌥W` | full width |
| `⌥O` | overview (`Esc` to leave) |
| `⌥C` | centre the focused window; off means the rail moves as little as it can |

### Flying between windows — `⌃Tab`

The arrows walk the rail — where the windows **stand**. `⌃Tab` walks the memory —
the order you **looked at** them in. On a rail of a dozen, the window you have
just come from can be six steps away in either direction; in the memory it is
always the next one.

Hold `⌃` and press `Tab`: a row of the profile's windows appears in the middle of
the screen as pictures, the one you would land on in the centre, its neighbours
in the ring peeking in at the edges. Under the row is what that page is, which
site it is from and which workspace it stands on — the ring crosses workspaces
too. `⌃⇧Tab` goes the other way, `Esc` lets go of the ring without changing
anything. Let `⌃` go and the rail flies to the window you chose.

Nothing loads while the ring is open: the cards are pictures taken of the
windows, and the page is built where you land. One press of `⌃Tab` is a toggle
between the last two windows. The ring holds this profile's windows only (each
profile has its own rail, history and colour — flying out of one on a keypress
would be too much) and only for this run.

## With the mouse alone

Nothing needs the keyboard: every operation has a mouse equivalent.

**A click on a background window** focuses it and pulls it to the middle. The
first click on somebody else's window never reaches the page — it is about the
window, not about what is drawn on it.

**The gaps beside the focused window.** Nothing is drawn there at rest. Sweep the
pointer in and the rail leans that way to show what is over there: a `‹` or a
`›` if it is a window, and an **outline of a window that does not exist yet** if
the rail has run out. A click on that sliver steps to the neighbour or opens a
new window — including one *before* the first, which is the only way the rail
grows backwards.

The sliver is as narrow as the gap it stands in and reaches the very edge of the
screen: throwing the pointer against the wall finds it.

::: tip View ▸ Peek at the Edges
The lean is a pointer idea: it is asked for by resting somewhere and waiting.
Turn the switch off and the arrows are simply drawn where they stand and work
without being hovered. It is on for macOS and always off on a phone.
:::

**Scrolling** over a gap, over the background or over the layout's own chrome
drives the rail: sideways by a window, up and down by a workspace. Over the page
itself, scrolling stays the page's. Over the top bar it does nothing — clicking
one of its buttons would be a gamble otherwise.

With `⌥` held the gestures work anywhere, the page included:

| | |
|---|---|
| `⌥` + vertical scroll | one workspace per gesture. Below the threshold the next one rubber-bands into view; once the switch commits, the rest of the gesture (trackpad momentum included) is swallowed, so a flick never skips two |
| `⌥` + horizontal scroll | one window per gesture while centring is on; with `⌥C` off, free panning |

**Pushing into a wall.** The rail is finite in both directions, the stack of
workspaces at the top and at the bottom. A gesture towards where there is nothing
used to be answered with nothing at all: the rail did not move, and the honest
reading of that is *the gesture got lost*. Now the edge you push into lights up
in the profile's colour and the rubber band stiffens — and the rail still does
not move, because that is exactly what is being said. The light fades on its own.
There is no bounce and no sound: a bounce is the rail moving, and the one thing
that has to stay true here is that it did not.

**Right-click the background** — a new window, a document, workspaces, the
overview, full width, settings. **Right-click a page ▸ This Window** — close,
full width, move left/right, move to the workspace above/below.

**The full-width button** on the left of the top bar, beside the profile: one
button with two states. It used to be a mode picker with a menu of eight things
hanging off it; two of those were switches, and switches are settings and live in
**Settings** now, while moving a window is what a right-click on the page is for.

**The workspace stepper** on the right: `⌃`/`⌄` step one workspace up and down, a
click on a pip jumps to it.

## Two ways to show a window

| | | |
|---|---|---|
| — | **the rail** | the ordinary one: the window is the screen less its outer gaps, in a card with corners |
| `⌥W` | **full width** | the page fills the window under the top bar: no gaps, no card, no corners |

This is a mode of the application, not a property of a window: `⌥←` `⌥→` go on
walking the rail, and the next window arrives filled as well — a workspace reads
like a stack of pages.

Switching is deliberately **not animated**, unlike everything else in the layout:
every switch resizes every live page, and a page changing size costs a visible
hitch. Better to get it over with than to spread it across a third of a second.

Leaving: the same key, **View ▸ Full Width**, or the button in the top bar. `Esc`
deliberately does **not** leave it: that is ordinary reading, where a page's own
`Esc` is worth more. The only thing `Esc` leaves is the overview.

::: warning There used to be a third
A *fullscreen* that took the top bar with it and gave back only a band of a bar
hiding at the top edge. It is gone: it was a second answer to the question full
width already answers — the difference between them is one 40-point bar — and it
cost the address field. macOS fullscreen via the green button and a video
player's own fullscreen are untouched and work as they always did.
:::

## The overview

`⌥O` zooms the whole canvas out: workspaces open up and read as separate screens.
The scale picks itself — just enough to show the focused rail end to end; a short
one is not shrunk for nothing, and a very long one starts scrolling rather than
turning microscopic.

In the overview:

- scrolling sideways runs along the rail, up and down goes through workspaces;
- a click on a window opens it and closes the overview;
- **dragging** carries a window along its rail or onto another workspace —
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
disappears — unless **you** gave it a name. **A workspace you named survives
being empty**, and that is the only way to book a place for a job in advance.

::: tip A name a program gave is not a booking
Research names a workspace after the question; an agent asks for
`workspace: "notes"` and gets one. That is a label on a room, not a booking: when
the last window leaves such a workspace the name goes with it and the row
disappears like any other empty one — otherwise a browser that answers questions
for a living silts up with empty workspaces carrying week-old questions. To keep
one, type the name yourself (double-click its plate in the overview) and it
becomes a booking.
:::

## How many pages are actually live

A page is a process of its own: its own memory, its own timers, its own
rendering. A rail of a hundred windows cannot carry a hundred of them, so VI
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
- The budget is sized from the machine's memory and cannot be changed: how many
  processes this Mac will carry is not a thing a person can know. **Settings ▸
  Windows** shows how many windows are holding a page right now, and offers
  **Unload Background Windows**.
- Under memory pressure the budget shrinks on its own and grows back when the
  pressure lifts.

There is no "blocked" counter here for the same reason there is none in blocking:
the number would have to be invented.
