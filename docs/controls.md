# Controls

Nothing needs the keyboard: every layout operation has a mouse equivalent. `⌥` stands in for niri's `Mod`.

## Mouse

| | |
|---|---|
| click a window | focuses it and scrolls it into view — the first click on a background window never reaches the page |
| the gaps beside the focused window | nothing is drawn there until the pointer arrives; sweep into one and the strip leans over to show the window on that side, with a `‹` or `›` fading in to say so. Click to step to it. (View ▸ **Peek at the Edges**, off, draws them where they stand instead and drops the lean — the only thing that works without a pointer, so it is the default off macOS.) Step to the last window and the sliver becomes the `+` below — under a pointer that has not moved, so it lets go of the peek and does nothing until you hover it again. The sliver is as narrow as the gap it stands in, runs its full height, and follows the focused window as the strip scrolls; with the window filled there is no gap left, so it shrinks to a band and waits at the edge of the screen — where throwing the pointer against the wall finds it |
| the gap at either end of the strip | where the strip runs out there is no arrow — the same sweep leans it over to show the window that *would* open there, outlined, with a `+` in the lane: after the last one, or, at the near end, **before the first**, which is the only way the strip grows backwards. Click anywhere in that sliver of gap to open it; move off and it all goes back |
| `⌃`/`⌄` beside the workspace pips | one workspace up/down |
| click a workspace pip | jump to that workspace |
| ⌘-click a link | opens it in a new window right of this one, **behind** — the focus stays on the page you are reading, and the strip leans right for a moment to show what arrived. To go there instead, the context menu's Open Link in New Window: WebKit swallows every shift-click before six sees it, and a middle click cannot be told from a plain one ([links.md](links.md)) |
| right-click a page | six's own menu: on a link, Open Link / in New Window / Behind / Download Linked File / Copy Link; always Back, Forward, Reload and the clipboard. WebKit's menu could not be repaired in place — [links.md](links.md) has why |
| the download ring (top bar) | there once something has been downloaded: what is coming in, Stop, and Show in Finder when it is done. A download flies there from the click, so it is clear both that it started and where it went ([links.md](links.md)) |
| right-click a page → This Window | close, full window, fullscreen, move left/right, move to the workspace above/below. It used to hang off the window's title bar; the page runs edge to edge now, so it hangs off the page |
| the layout button (top left, beside the profile) | click fills the window and back (`⌥W`); hold for the list — strip / full window / fullscreen, overview, centring, and where the focused window goes in the strip (move left/right, to the workspace above/below, close) |
| right-click the background | new window, workspace up/down, overview, centring on/off |
| scroll over a gap or the background | one window sideways / one workspace up-down per gesture — over a page or a panel, scrolling stays the page's, and over the top bar it does nothing (its buttons would be a gamble otherwise) |
| the address field (top bar) | one field, for the window you are reading, with back/forward/reload beside it, and the lock, the shield, the camera light and the highlighter with it. `⌘L` puts the caret in it. A window has no title bar of its own at all: it is a page from edge to edge |
| the bookmark star (top bar) | save the focused page — filled when it is saved, a spinner while it is being indexed; again to remove. `⌘⌥B` lists and searches them |
| overview button (top right) | zoom out to all workspaces; scroll sideways to run along a strip, click a window to open it |
| double-click a workspace name (overview) | rename it; right-click the name to rename or clear it. A named workspace stays even when empty |
| drag a window (overview) | carry it along its strip to reorder it, or up and down onto another workspace — including the empty one at the bottom, which is how a workspace gets made. The row it came from closes up, a gap opens where it would land, and the focus goes with it when it is let go |
| the lock / globe in the address field | once a site has been answered about the camera, the microphone or the motion sensors: flip an answer, forget the site, or open the whole list ([permissions.md](permissions.md)) |
| the red camera / mic in the address field | only while the page is actually using one — click to mute it, click again to let it see and hear |
| `×` on a window's top right corner | close that window. It sits on the corner itself — mostly over the gap, so the page keeps its clicks — and it is invisible until the pointer is on it, so a strip of a dozen windows is not a row of a dozen crosses |
| the top edge of the screen (in fullscreen) | brings the bar back: previous/next window, workspace up/down, overview, leave fullscreen |
| the engine chip on the start page | DuckDuckGo or Google — for queries and for the suggestions; also under Navigate → Search Engine |
| the profile button (top left) | which profile you are in, by name. It opens onto the list: click one to switch (each has its own strip), or unfold a row to rename it, pick its colour and delete it. New Profile at the bottom, and Private Window when there isn't one |

## Keyboard

Every binding is in [hotkeys.md](hotkeys.md). In short: `⌥` + arrows / scroll move around the strip, `⌥W`
`⌥⇧F` `⌥O` `⌥C` change how a window is shown, `⌘T` `⌘W` `⌘L` `⌘K` `⌘D` `⌘⌥B` `⌘Y` `⌘⇧A` are the browser's.
