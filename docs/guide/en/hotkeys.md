# Keyboard shortcuts

`⌥` is the rail, `⌘` is the browser. There is no menu for the `⌥` keys: they are
read before the page is, which is what makes them always answer. None of it is
required: [every operation has a mouse
equivalent](/en/layout#with-the-mouse-alone).

## The rail

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window left / right |
| `⌥Home` `⌥End` | first / last window on the rail |
| `⌥↑` `⌥↓` | workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below and follow it |
| `⌥W` | full width |
| `⌥O` | overview (`Esc` to leave) |
| `⌥C` | centre the focused window (on by default) |
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | one window per gesture |

Where the rail has run out, the gesture is not lost in silence: the edge you
pushed into lights up in the profile's colour, the rubber band stiffens, and
nothing moves — because there is nothing that way.

## Flying between windows

| | |
|---|---|
| `⌃Tab` | hold `⌃`: the profile's windows as pictures, in the order you last looked at them, with the one you would land on in the middle. Each press steps one along the ring; letting `⌃` go flies there |
| `⌃⇧Tab` | the same, the other way |
| `Esc` | let go of the ring without going anywhere |

`⌥←` `⌥→` walk the rail — where the windows **stand**; `⌃Tab` walks the memory —
the order they were **looked at** in. Which is why one press of `⌃Tab` is a
toggle between the last two windows. This profile's windows only, and this run
only.

## Browser

| | |
|---|---|
| `⌘,` | settings — `six://settings`, a column of the rail like any other address |
| `⌘T` | a new window on the rail, right of the focused one |
| `⌘W` | close the focused window |
| `⌘⇧T` | put the last closed window back where it stood |
| `⌘⇧N` | a new document |
| `⌘⇧P` | a new private window |
| `⌘L` | focus the address field |
| `⌘K` | the assistant line |
| `⌘⇧A` | the agent panel |
| `⌘Y` | the profile's history |
| `⌘D` | bookmark the focused page (again: remove it) |
| `⌘⌥B` | bookmarks and the search across them |
| `⌘S` / `⌘⇧S` | save / save as… |
| `⌘⇧L` | translate the page |
| `⌥⇧T` | translate the selection |
| `⌥⇧H` | highlight the selection on the page |
| `⌘` + click a link | open it in a new window to the right, behind |
| `Esc` | close the overview; otherwise the page's own |

## The start page

| | |
|---|---|
| typing | completions: an address, pages from history, the engine's suggestions |
| `↑` `↓` | walk the rows |
| `↩` | open the selected row, or what you typed |
| `Esc` | clear the field |

## Bookmarks (`⌘⌥B`)

| | |
|---|---|
| typing | search by meaning; the matching passage under each row |
| `↑` `↓` `↩` | walk the rows, open in a new window |
| `⌫` | remove the bookmark and its file |
| `Esc` | close |

## History (`⌘Y`)

| | |
|---|---|
| typing | filter by title and address |
| `↩` | open in a new window |
| `⌫` | forget the visit |
| `Esc` | close |

## The agent panel (`⌘⇧A`)

| | |
|---|---|
| `↩` | send |
| `⌘↩` | send, even while the field is multi-line |

## The overview

| | |
|---|---|
| `↩` | commit a workspace's name while renaming it |

::: tip Two things worth knowing
`⌥W`, `⌥O` and `⌥C` are taken before anything else sees them, so those characters
cannot be typed into a field.

The arrows are not: while the caret is in the address field or the ⌘K line, `⌥←`
and `⌥→` are word movement, as they always were. Inside a page they belong to the
rail — a text field on a page cannot be told apart from the page around it.
:::
