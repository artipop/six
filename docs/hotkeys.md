# Hotkeys

Every key binding in six, in one place. `⌥` stands in for niri's `Mod`; `⌘` bindings are the browser's own. Each
row is backed by a key monitor, a menu item or a view — the file is named so nothing here can drift from the code:
`NiriScrollMonitor` in `six/Niri/`, `ViewCommands` / `HistoryCommands` / `BookmarkCommands` in `six/Views/MacCommands.swift`,
the File menu in `six/sixApp.swift`, `FileCommands` in `six/Documents/Export.swift`, the rest in `six/Views/`.

## The rail (`⌥` — `NiriScrollMonitor.onLayoutKey`)

Not a menu. These used to be a **Layout** menu of eleven items, ten of which were an arrow key, and that menu
could not make them work anyway: a first-responder `WKWebView` answers a key equivalent before the menu bar sees
it and keeps `⌥←` / `⌥→` for word movement, so after clicking into a page the layout keys went quiet. They come
through a local `NSEvent` monitor now, which runs before all of it. The one thing given back is a text field:
while the caret is in one of six's own, `⌥` and an arrow is word and paragraph movement, as it always was.

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window left / right |
| `⌥Home` `⌥End` | first / last window on the rail |
| `⌥↑` `⌥↓` | focus the workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below (and follow it) |
| `⌥W` | full width — the page fills the window under the top bar; again to leave (also View ▸ Full Width, and the button beside the profile) |
| `⌥O` | overview on / off; `Esc` also leaves it (also View ▸ Overview) |
| `⌥C` | centre the focused window (on by default) — off means the rail moves as little as possible. The switch is on `six://settings` ▸ Windows |
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | one window per gesture while centring is on; free panning with `⌥C` off |

Where the rail runs out, the gesture is answered rather than ignored: the edge pushed into lights up
in the profile's colour and the rubber band gives less, and nothing moves, because there is nothing
that way ([layout.md](layout.md#the-ends-of-the-rail)).

## Browser (`⌘`)

| | |
|---|---|
| `⌘,` | settings — `six://settings`, in a column of the rail like any other address |
| `⌘T` | new window on the rail, right of the focused one |
| `⌘⇧N` | new document — a Markdown column next to the pages (edit / preview in the top bar, where its address would be) |
| `⌘⇧P` | new private window — in the private profile (created on the first press; in-memory session, nothing recorded); File → Close Private Browsing forgets it |
| `⌘W` | close the focused window |
| `⌘⇧T` | put the last closed window back where it stood, showing what it showed — ten deep, this run only. A private window is not on the list, and neither is one that never showed anything |
| `⌘S` | save — a document that has a file goes back to it; otherwise Save As |
| `⌘⇧S` | save as… — a document as `.md` / `.html` / `.pdf`, a page as `.html` / `.pdf` / `.txt`; the folder is remembered |
| `⌥⇧H` | highlight the selection on the page; it comes back when the page is opened again (File → Remove Highlights on This Page to clear) |
| `⌘L` | focus the address field |
| `⌘K` | focus the assistant line |
| `⌘⇧A` | agent panel on / off |
| `⌘Y` | history of the current profile |
| `⌘D` | bookmark the focused page (again: remove the bookmark) |
| `⌘⌥B` | bookmarks, searchable by meaning |
| `⌘` + click a link | open it in a new window right of this one, behind — the rail leans right for a moment to show it. `⇧` and `⌘⇧` clicks do nothing at all: WebKit never passes them on, and a middle click arrives indistinguishable from a plain one ([links.md](links.md)) |
| `Esc` | close the overview; otherwise the page's own |

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

- `⌥W` / `⌥O` / `⌥C` are taken before anything else sees them, so those `⌥`+letter characters can't be typed
  into a field. The arrows are not: `NiriScrollMonitor.isEditingText` lets them through while the caret is in one
  of six's own fields. A field *inside a page* can't be told apart from the page around it, and the rail wins there.
- To move the whole layout set to another modifier, change `NiriScrollMonitor.modifier` — one constant now, since
  the keys are read there and nowhere else. The two `.keyboardShortcut`s left in `ViewCommands` (`⌥W`, `⌥O`) are
  for display and for the pointer; the monitor swallows the key before the menu can act on it.
