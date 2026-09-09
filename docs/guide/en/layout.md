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

Hold `⌃` and press `Tab`: a row of windows appears in the middle of the screen as
pictures, the one you would land on in the centre, its neighbours in the ring
peeking in at the edges. Under the row are the page's title and its site.
`⌃⇧Tab` goes the other way, `Esc` lets go of the ring without changing anything.
Let `⌃` go and the rail flies to the window you chose.

Nothing loads while the ring is open: the cards are pictures taken of the
windows, and the page is built where you land. One press of `⌃Tab` is a toggle
between the last two windows.

A split column is **one** stop in the ring, and its card draws both halves the
way they stand on the rail — the one you would land in at full strength. Walking
the halves separately would be pointless: they are both in front of you already,
and `⌥←` / `⌥→` are what move between them.

A rail with one window on it still opens the ring — with one card in it. The key
has to answer: a press that gives nothing back cannot be told from an unbound key
or from a browser that has stopped listening, and this one is held, so the
nothing would last as long as your hand does. Only an empty rail refuses, and
there the screen already says so in the middle.

**The ring holds the windows of the rail you are looking at** — not the other
workspaces, and certainly not another profile. A workspace is a place you went to
on purpose and a profile is a world of its own with its own history and logins;
flying out of either on a keypress is a much bigger move than the key looks, and
`⌥↑` / `⌥↓` are there for workspaces and say where they are going. The ring's
memory lasts for this run only.

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
cost the address field. macOS fullscreen via the green button still does what
people actually want from the word, and a video player's own fullscreen button
now works too — it had been quietly refused before.
:::

## Two windows in one column

`⌥S` takes the window next along into the one you are reading: they share a
column, side by side, and the rail is one column shorter. `⌥S` again and they are
two separate windows on the rail. So do **View ▸ Split**, the rail's own
right-click menu, the **This Window** menu, and — in the overview — one window
dropped onto another.

| | |
|---|---|
| `⌥S` | take the neighbouring window into this column; again to put it back on the rail |
| `⌥←` `⌥→` | walk the halves exactly as they walk windows: into the near half first, then on to the next column |
| `⌥⇧←` `⌥⇧→` | inside a pair, swap the two halves |
| `⌥⇧↑` `⌥⇧↓` | take **the half you are reading**; the other one stays where it stood |

The column is still exactly one screen's worth of rail: the two halves fill what
one window filled, so the rail does not get longer and nothing shifts. The gap
between the halves is deliberately half the one between columns — at the same
width the pair would read as two neighbouring windows rather than as one.

The halves are windows in their own right, not panes of one: each has its own
border, its own ×, its own loading line. Closing one closes one window, and the
other stays where it stood with the column to itself.

The keyboard travels with the focus: after `⌥→` the arrow keys scroll the half
that is highlighted, and typing goes into it. The one exception is a caret in a
field — `⌘L` and the `⌘K` line are left by keystroke, and the rail does not take
what you are typing away from them.

A click on the other half lands the focus on it first, as on any unfocused
window, and only the next one reaches the page: the address field, `⌘W` and `⌘K`
all speak for the focused window, and a page that answered a click without
becoming the focused one would leave every one of them pointing at its
neighbour.

More than two do not fit, and that is a decision rather than a limit: three pages
at a third of a screen each are three pages nobody can read, and "I want to see
more than two things at once" is what the rail itself answers.

::: tip With the mouse
In the **overview**, a window let go over the *middle* of another joins its
column; let go at the edge of one, or between two, it stands beside them as
before. While you hold it over the middle you see two things at once: that column
opens its other half in advance, and an outline in the profile's colour marks
**exactly the place** the window will land in. A link can be opened beside
straight away: **Open Link Beside** in the page's context menu.
:::

Going from half to whole and back is deliberately **not animated**, like full
width and for the same reason: it changes how wide live pages are, and a page
changing size costs a visible hitch. While the width eased, the site would lay
itself out again on every frame — and find time to show a horizontal scrollbar.

## Picture in Picture

`⌥⇧P`, or **View ▸ Picture in Picture**, or the button that appears in the
player's own controls: the video leaves the page for a small window that floats
above everything — above six, above your editor, above whatever you switch to
next. The same key puts it back.

The page it came from stays on the rail exactly where it was. Scroll away from
it, step to the workspace below, switch to another profile: the little window
stays where you put it and goes on playing. The page behind it is never unloaded
to save memory while the video is up, so coming back to it finds it as you left
it.

The menu item is never greyed out, because only the page knows whether it has a
video to float, and that changes with every play and pause. On a page of text,
pressing it does nothing at all.

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
disappears — silently and at once, as it should: an empty unnamed workspace is
nothing.

**If it has a name, VI asks first:** *Delete the workspace "Tickets"?* —
**Delete** or **Keep It**. One rule for every name, on purpose: you are not the
only one who names workspaces here. Research names one after its question, an
agent asks for `workspace: "notes"` and gets one. Which of those names is a
booking and which is a label on a room is not something VI can tell, and it does
not guess — it asks whoever is there.

- **Delete** — the workspace goes, and the name with it.
- **Keep It** — it stays, empty, with its name. That is how you book a place for
  a job in advance. You are asked again only if it fills up and empties again.
- Dismissing the dialog some other way (`Esc`, a click outside) means keep.
  Silence is not consent to delete.

::: tip A workspace that is already standing empty
Workspaces that emptied before this question existed were never asked about.
Right-click the workspace's plate in the overview ▸ **Delete Workspace**, and it
is gone.
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
  field or a filled-in password is discarded — nor is a page whose video is in
  the floating picture-in-picture window, even when it is paused.
- The budget is sized from the machine's memory and cannot be changed: how many
  processes this Mac will carry is not a thing a person can know. **Settings ▸
  Windows** shows how many windows are holding a page right now, and offers
  **Unload Background Windows**.
- Under memory pressure the budget shrinks on its own and grows back when the
  pressure lifts.

There is no "blocked" counter here for the same reason there is none in blocking:
the number would have to be invented.
