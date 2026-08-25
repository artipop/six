# Controls

Nothing needs the keyboard: every layout operation has a mouse equivalent. `⌥` stands in for niri's `Mod`.

## Mouse

| | |
|---|---|
| click a window | focuses it and scrolls it into view — the first click on a background window never reaches the page |
| `‹` `›` on the screen edges | one window left/right; they only appear when the strip continues that way |
| `⌃`/`⌄` beside the workspace pips | one workspace up/down |
| click a workspace pip | jump to that workspace |
| `+` in the top bar | new window, right of the focused one |
| right-click a window's title bar | close, cycle width, maximize, move left/right, move to the workspace above/below |
| right-click the background | new window, workspace up/down, overview |
| scroll over a title bar, a gap or the background | pans the strip (horizontal) / changes workspace (vertical) — over a page or a panel, scrolling stays the page's |
| overview button (top right) | zoom out to all workspaces; a click there opens a window |
| `×` on a title bar | close that window |
| the profile dots (top left) | switch profile — each has its own strip; `+` adds one, right-click deletes |

## Keyboard

| | |
|---|---|
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | free panning; focus snaps to the window nearest the middle on release |
| `⌥←` `⌥→` / `⌥⇧←` `⌥⇧→` | focus / move a window |
| `⌥↑` `⌥↓` / `⌥⇧↑` `⌥⇧↓` | focus a workspace / move the window to it |
| `⌥Home` `⌥End` | first / last window in the strip |
| `⌥R` / `⌥F` | cycle preset widths (½, ⅔, peek, full) / maximize |
| `⌥O`, `Esc` | overview on / off |
| `⌘T` / `⌘W` | new window / close window |
| `⌘L` | focus the address field |
| `⌘K` | focus the assistant line |
| `⌘⇧A` | agent panel |

Because the Layout menu owns `⌥R` / `⌥F` / `⌥O`, those `⌥`+letter characters can't be typed into the address field.
Changing `NiriScrollMonitor.modifier` and the matching `.keyboardShortcut` modifiers in `LayoutCommands` moves the
whole binding set to another key.
