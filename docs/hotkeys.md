# Hotkeys

Every key binding in six, in one place. `⌥` stands in for niri's `Mod`; `⌘` bindings are the browser's own. Each
row is backed by a menu item or a view — the file is named so nothing here can drift from the code:
`LayoutCommands` / `BrowserCommands` / `HistoryCommands` in `six/sixApp.swift`, `FileCommands` in `six/Documents/Export.swift`, the rest in `six/Views/`.

## Layout (`⌥` — Layout menu)

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window left / right |
| `⌥Home` `⌥End` | first / last window in the strip |
| `⌥↑` `⌥↓` | focus the workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below (and follow it) |
| `⌥R` / `⌥⇧R` | wider / narrower — every window steps one preset (½, ⅔, peek, full), stopping at the ends; the current one is checked in the menu |
| `⌥F` | compact width — this window at the widest tiled preset, gaps and title bar still there; again to go back |
| `⌥W` | full window — the page fills the window under the top bar; again to leave |
| `⌥⇧F` | fullscreen — the page edge to edge, `⌥←` `⌥→` still walk the strip; again or `Esc` to leave |
| `⌥O` | overview on / off; `Esc` also leaves it |
| `⌥C` | centre the focused window (on by default) — off means the strip moves as little as possible |
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | one window per gesture while centring is on; free panning with `⌥C` off |

## Browser (`⌘`)

| | |
|---|---|
| `⌘T` | new window in the strip, right of the focused one |
| `⌘⇧N` | new document — a Markdown column next to the pages (edit / preview in its title bar) |
| `⌘⇧P` | new private window — in the private profile (created on the first press; in-memory session, nothing recorded); File → Close Private Browsing forgets it |
| `⌘W` | close the focused window |
| `⌘S` | save — a document that has a file goes back to it; otherwise Save As |
| `⌘⇧S` | save as… — a document as `.md` / `.html` / `.pdf`, a page as `.html` / `.pdf` / `.txt`; the folder is remembered |
| `⌥⇧H` | highlight the selection on the page; it comes back when the page is opened again (File → Remove Highlights on This Page to clear) |
| `⌘L` | focus the address field |
| `⌘K` | focus the assistant line |
| `⌘⇧A` | agent panel on / off |
| `⌘Y` | history of the current profile |
| `⌘D` | bookmark the focused page (again: remove the bookmark) |
| `⌘⌥B` | bookmarks, searchable by meaning |
| `⌘` + click a link | open it in a new window right of this one, behind — the strip leans right for a moment to show it. `⇧` and `⌘⇧` clicks do nothing at all: WebKit never passes them on, and a middle click arrives indistinguishable from a plain one ([links.md](links.md)) |
| `Esc` | leave fullscreen, or close the overview; otherwise the page's own |

## Start page (a new window)

| | |
|---|---|
| typing | completions: an address row when the input looks like one, then pages from the profile's history, then the engine's suggestions |
| `↑` `↓` | walk the rows |
| `↩` | open the selected row, or the raw input (address, or a search) |
| `Esc` | clear the field |

## Address field (`⌘L`)

| | |
|---|---|
| `↩` | open the address, or search for the text |

## Bookmarks (`⌘⌥B`)

| | |
|---|---|
| typing | search by meaning across the profile's (or every profile's) saved pages; the matching passage under each |
| `↑` `↓` | walk the rows |
| `↩` | open the selected row (or the first) in a new window |
| `⌫` | remove the bookmark and its file |
| `Esc` | close |

## History (`⌘Y`)

| | |
|---|---|
| typing | filter by title and address |
| `↩` | open the selected visit (or the first match) in a new window |
| `⌫` | forget the selected visit |
| `Esc` | close |

## Assistant line (`⌘K`)

| | |
|---|---|
| `↩` | ask; the answer streams under the line |
| `↩` in the API-key sheet | done |

## Agent panel (`⌘⇧A`)

| | |
|---|---|
| `↩` | send |
| `⌘↩` | send (also while the field is multi-line) |

## Overview

| | |
|---|---|
| `↩` while renaming a workspace | commit the name |

## Notes

- Because the Layout menu owns `⌥R` / `⌥F` / `⌥W` / `⌥O` / `⌥C`, those `⌥`+letter characters can't be typed into the
  address field.
- To move the whole layout set to another modifier, change `NiriScrollMonitor.modifier` and the matching
  `.keyboardShortcut` modifiers in `LayoutCommands`.
- A web view that is first responder gets key equivalents before the menu bar, and keeps `⌥←` / `⌥→` (word
  movement) for itself; after Full Window the layout keys may not answer until something outside the page is
  clicked. Known; the fix (routing `⌥` keys to the menu first) is on hold.
