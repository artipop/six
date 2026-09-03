# Hotkeys

Every key binding in six, in one place. `⌥` stands in for niri's `Mod`; `⌘` bindings are the browser's own. Each
row is backed by a key monitor, a menu item or a view — the file is named so nothing here can drift from the code:
**`KeyBindings` in `six/Input/`** for everything a menu cannot keep, `ViewCommands` / `HistoryCommands` /
`BookmarkCommands` in `six/Views/MacCommands.swift`, the File menu in `six/sixApp.swift`, `FileCommands` in
`six/Documents/Export.swift`, the rest in `six/Views/`.

The split is worth stating once: **`⌘` belongs to the menu bar** — which shows the key, greys it out when it cannot
be pressed, and is where a person looks for it — and **everything else belongs to `KeyBindings`**, one array walked by
one `NSEvent` monitor (`KeyRouter`). A binding is in the table when a menu item cannot deliver it: a first-responder
`WKWebView` answers a key equivalent before the menu bar is asked, and keeps `⌥←` for word movement.

## The rail (`⌥` — `KeyBindings`, scope `.rail`)

Not a menu. These used to be a **Layout** menu of eleven items, ten of which were an arrow key, and that menu
could not make them work anyway: a first-responder `WKWebView` answers a key equivalent before the menu bar sees
it and keeps `⌥←` / `⌥→` for word movement, so after clicking into a page the layout keys went quiet. They come
through a local `NSEvent` monitor now, which runs before all of it.

What is given back to a text field is worked out **per key and per caret**, not per field
(`KeyBinding.Key.yields(to:)`). `⌥←` is word movement and always was — but only while there is a word behind the
caret to move over; on the empty field a fresh window opens with, the same key is the only way to walk off it.
`⌥↑` is paragraph movement, which a one-line field does not have, so there it stays the rail's. A field *inside a
page* cannot be told apart from the page around it, and the rail wins there.

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

## Flying between windows (`⌃` — `KeyBindings`, scope `.switcher`)

| | |
|---|---|
| `⌃Tab` | hold `⌃`: the windows on the rail in front of you, as pictures, in the order they were last looked at, the one you would land on in the middle. Each press steps one along the ring; letting `⌃` go flies there |
| `⌃⇧Tab` | the same, the other way |
| `⌃←` `⌃→` | the same step, said the way the row of cards is drawn |
| `↩` | fly now, without waiting for `⌃` to come up |
| `Esc` | let go of the ring without going anywhere |

While the ring is up it is on top of everything else in the window: its own keys answer first, and any other key
lands the flight and goes on to whatever it was meant for.

The rail's order and this one are different questions: `⌥←` / `⌥→` walk the windows where they stand,
`⌃Tab` walks them in the order they were used, so a single press is a toggle between the last two.
One rail's windows only — the workspace on screen — and this run only. `⌥↑` / `⌥↓` are what move between workspaces, and they say where they are going.

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
| `↑` `↓` | walk the rows — from the field, without clicking into the list first (`walksRows`) |
| `↩` | open the selected row (or the first) in a new window |
| `⌘⌫` | remove the bookmark and its file, and land on the row that takes its place |
| `⌫` | the same, while the list itself has the focus — in the field it is a character being deleted |
| `Esc` | close |

## History (`⌘Y`)

| | |
|---|---|
| typing | filter by title and address |
| `↑` `↓` | walk the rows — from the field, without clicking into the list first (`walksRows`) |
| `↩` | open the selected visit (or the first match) in a new window |
| `⌘⌫` | forget the selected visit, and land on the row that takes its place |
| `⌫` | the same, while the list itself has the focus |
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

- **A letter binding answers to the key's position as well as to what is printed on it.** `⌥W` on a Russian layout
  reports «ц» from `charactersIgnoringModifiers`; matching only that is why `⌥W` / `⌥O` / `⌥C` were dead for anyone
  not typing in Latin. `KeyBinding.Key.letter` matches either the US key code or the character, so the three work on
  a Cyrillic layout (by position) and on Dvorak (by letter).
- `⌥W` / `⌥O` / `⌥C` / `⌥⇧T` / `⌥⇧H` are taken before anything else sees them, so those `⌥`+letter characters can't
  be typed into a field. The arrows are not — see the rail section for the rule.
- **Nothing in the table answers outside six's own window.** A sheet, a popover and WebKit's full-screen video are
  `KeyContext.Window.elsewhere`, and there `⎋` closes the sheet instead of the overview behind it and `⌥O` does
  nothing at all.
- To move the whole layout set to another modifier, change the `.exactly(.option)` rows in `KeyBindings.all` — the
  keys are read there and nowhere else. The `.keyboardShortcut`s left in `ViewCommands` and `FileCommands` (`⌥W`,
  `⌥O`, `⌥⇧T`, `⌥⇧H`) are for display and for the pointer; the router swallows the key before the menu can act on it.
- **`SIX_UI_DEBUG=1` prints a line per key** — the chord, the context it landed in, and who took it. **`SIX_KEY_SELFTEST=1`**
  prints the whole matrix at launch: every binding against every context, which is how a binding that goes quiet
  somewhere is found without pressing anything (`KeySelfTest`; this Mac cannot press its own keys, see CLAUDE.md).
