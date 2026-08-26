# Controls

Nothing needs the keyboard: every layout operation has a mouse equivalent. `⌥` stands in for niri's `Mod`.

## Mouse

| | |
|---|---|
| click a window | focuses it and scrolls it into view — the first click on a background window never reaches the page |
| `‹` `›` on the screen edges | one window left/right; they only appear when the strip continues that way |
| `+` on the right edge | at the end of the strip the right chevron becomes a `+`: a new window after the last one |
| `⌃`/`⌄` beside the workspace pips | one workspace up/down |
| click a workspace pip | jump to that workspace |
| right-click a window's title bar | close, cycle width, compact width, full window, fullscreen, move left/right, move to the workspace above/below |
| right-click the background | new window, workspace up/down, overview, centring on/off |
| scroll over a title bar, a gap or the background | one window sideways / one workspace up-down per gesture — over a page or a panel, scrolling stays the page's, and over the top bar it does nothing (its buttons would be a gamble otherwise) |
| overview button (top right) | zoom out to all workspaces; scroll sideways to run along a strip, click a window to open it |
| double-click a workspace name (overview) | rename it; right-click the name to rename or clear it. A named workspace stays even when empty |
| `×` on a title bar | close that window |
| `⤢` in the top bar | full window: the page takes the whole window under the bar; press it again to come back |
| the top edge of the screen (in fullscreen) | brings the bar back: previous/next window, workspace up/down, overview, leave fullscreen |
| the engine chip on the start page | DuckDuckGo or Google — for queries and for the suggestions; also under Navigate → Search Engine |
| the profile dots (top left) | switch profile — each has its own strip; `+` adds one, right-click deletes |

## Keyboard

| | |
|---|---|
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | one window per gesture while centring is on; free panning with `⌥C` off, snapping to the nearest window on release |
| `⌥←` `⌥→` / `⌥⇧←` `⌥⇧→` | focus / move a window |
| `⌥↑` `⌥↓` / `⌥⇧↑` `⌥⇧↓` | focus a workspace / move the window to it |
| `⌥Home` `⌥End` | first / last window in the strip |
| `⌥R` / `⌥F` | cycle preset widths (½, ⅔, peek, compact full) / compact width — the widest tiled one, gaps and title bar still there |
| `⌥W` | full window: the page fills the window under the top bar — no gaps, no title bar |
| `⌥C` | centre the focused window in the strip (on by default) — off means the strip moves as little as possible |
| `⌥O`, `Esc` | overview on / off |
| `⌥⇧F`, `Esc` | fullscreen on / off — the page edge to edge, with `⌥←` `⌥→` still walking the strip |
| `⌘Y` | history of the current profile (search, ↩ opens, ⌫ forgets); the History menu has the last 20 pages |
| `⌘T` / `⌘W` | new window / close window |
| `⌘L` | focus the address field |
| `⌘K` | focus the assistant line |
| `⌘⇧A` | agent panel |

Because the Layout menu owns `⌥R` / `⌥F` / `⌥W` / `⌥O`, those `⌥`+letter characters can't be typed into the address field.
Changing `NiriScrollMonitor.modifier` and the matching `.keyboardShortcut` modifiers in `LayoutCommands` moves the
whole binding set to another key.
