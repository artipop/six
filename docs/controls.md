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
| ⌘-click / middle-click a link | opens it in a new window right of this one, **behind** — the focus stays on the page you are reading, and the strip leans right for a moment to show what arrived. To go there instead, the context menu's Open Link in New Window: WebKit swallows every shift-click before six sees it ([links.md](links.md)) |
| right-click a page | six's own menu: on a link, Open Link / in New Window / Behind / Download Linked File / Copy Link; always Back, Forward, Reload and the clipboard. WebKit's menu could not be repaired in place — [links.md](links.md) has why |
| the download ring (top bar) | there once something has been downloaded: what is coming in, Stop, and Show in Finder when it is done. A download flies there from the click, so it is clear both that it started and where it went ([links.md](links.md)) |
| right-click a window's title bar | close, column width (checked), compact width, full window, fullscreen, move left/right, move to the workspace above/below |
| right-click the background | new window, workspace up/down, overview, centring on/off |
| scroll over a title bar, a gap or the background | one window sideways / one workspace up-down per gesture — over a page or a panel, scrolling stays the page's, and over the top bar it does nothing (its buttons would be a gamble otherwise) |
| the bookmark star (top bar) | save the focused page — filled when it is saved, a spinner while it is being indexed; again to remove. `⌘⌥B` lists and searches them |
| overview button (top right) | zoom out to all workspaces; scroll sideways to run along a strip, click a window to open it |
| double-click a workspace name (overview) | rename it; right-click the name to rename or clear it. A named workspace stays even when empty |
| the lock / globe in an address field | once a site has been answered about the camera, the microphone or the motion sensors: flip an answer, forget the site, or open the whole list ([permissions.md](permissions.md)) |
| the red camera / mic in an address field | only while the page is actually using one — click to mute it, click again to let it see and hear |
| `×` on a title bar | close that window |
| the top edge of the screen (in fullscreen) | brings the bar back: previous/next window, workspace up/down, overview, leave fullscreen |
| the engine chip on the start page | DuckDuckGo or Google — for queries and for the suggestions; also under Navigate → Search Engine |
| the profile dots (top left) | switch profile — each has its own strip; `+` adds one, right-click deletes |

## Keyboard

Every binding is in [hotkeys.md](hotkeys.md). In short: `⌥` + arrows / scroll move around the strip, `⌥R` `⌥F` `⌥W`
`⌥⇧F` `⌥O` `⌥C` change how a window is shown, `⌘T` `⌘W` `⌘L` `⌘K` `⌘D` `⌘⌥B` `⌘Y` `⌘⇧A` are the browser's.
