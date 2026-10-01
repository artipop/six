# Hotkeys

Every key binding in Savoia, in one place. Each row is backed by a key monitor, a menu item or a view:
**`KeyBindings` in `Savoia/Input/`** for everything a menu cannot keep, `ViewCommands` / `HistoryCommands` /
`BookmarkCommands` in `Savoia/Views/MacCommands.swift`, the File menu in `Savoia/SavoiaApp.swift`, `FileCommands` in
`Savoia/Documents/Export.swift`, the rest in `Savoia/Views/`.

**This file is checked against the code.** `Tests/SavoiaCoreTests/KeyBindingsTests.swift` reads it and asks the
table about it in both directions: every binding has to be written down here, and every key the page and ring
tables below promise has to resolve to one.

The split is worth stating once: **`⌘` belongs to the menu bar** — which shows the key, greys it out when it cannot
be pressed, and is where a person looks for it — and **the rest belongs to `KeyBindings`**, one array walked by one
`NSEvent` monitor (`KeyRouter`). A binding is in the table when a menu item cannot deliver it: a first-responder
`WKWebView` answers a key equivalent before the menu bar is asked.

## Page keys on macOS

Return, keypad Enter, Space, Esc, the arrows, Home, End, Page Up and Page Down, alone or with Shift,
belong to the page: typing, submitting a form, activating a button, moving the caret, scrolling or a
site's key handler. With nothing to do they stay quiet.

WebKit sends an unhandled key back through AppKit (`WebViewImpl::doneWithKeyEvent`), and its second
`keyDown` forwards it to the responder chain. That reached `NSResponder.noResponder(for:)` and rang
the system alert on a short page. `PageKeyFallback`, installed by `WebViewResponder`, stands **after
the host window** in that chain. It accepts only these unhandled keys, without Command, Control or
Option, while a `WKWebView` is the first responder. The DOM and the window's default button have
already had their turns; native fields, sheets and menu shortcuts keep their normal paths.

`SAVOIA_KEY_SELFTEST=alert` in a Debug build checks this in the actual browser. It observes AppKit's
unhandled-key endpoint, posts key-down/up events and verifies the DOM's counts and effects: each of those
keys on a short page, scrolling pages, fields, forms, buttons, cancelled events and held-key repeats, the
address field, the window's default button, native sheet fields and the switcher. Synthetic events enter
the app's queue, so this does not test WindowServer's own shortcuts.

## The page (`⌥⇧` — `KeyBindings`, scope `.window`)

Offered to the page first (`KeyBinding.Precedence.pageFirst`): the key goes to the page, and Savoia answers only if
WebKit hands it back unhandled — the way Chrome and Firefox treat every shortcut they do not reserve. In one of
Savoia's own fields the letter is typed instead (`KeyBinding.yieldsToCaret(in:)`).

| | |
|---|---|
| `⌥⇧T` | translate the selection (View ▸ Translate Selection…) |
| `⌥⇧H` | highlight the selection on the page; it comes back when the page is opened again (File → Remove Highlights on This Page to clear) |
| `⌥⇧P` | the tab's video into the floating picture-in-picture player, and out of it again |
| `⌘⇧C` | copy the address of the tab you are reading — the field shows a tick (Edit ▸ Copy Address). **Reserved**, not offered to the page: a `⌘` chord offered to a focused page never comes back. Nothing to copy on a start page, a document or an app, and there the key is left to whatever else wants it |

## Flying between tabs (`⌃` — `KeyBindings`, scope `.switcher`)

| | |
|---|---|
| `⌃Tab` | hold `⌃`: every tab of the profile, in every group, folded ones included, as pictures in the order they were last looked at, the one you would land on in the middle. Each press steps one along the ring; letting `⌃` go flies there. Settings → Windows → *Control-Tab Switches* can make the order that of the tab bar instead (`⌃⇧Tab` then goes back along it) |
| `⌃⇧Tab` | opens the same ring over the group in front; once the ring is up, a step the other way |
| `⌃⇧←` `⌃⇧→` | one card along, the way they are drawn. `⌥` instead of `⇧` does the same: the arrows are bound for **any** modifiers, and the ⇧ is there to get past macOS |
| `↩` `⌤` | fly now, without waiting for `⌃` to come up |
| `Esc` | let go of the ring without going anywhere |

While the ring is up it is on top of everything else in the window: its own keys answer first, and any other key
lands the flight and goes on to whatever it was meant for — including over a caret in a field.

## Browser (`⌘`)

| | |
|---|---|
| `⌘R` | load the page again (also the ⟳ button beside the address) |
| `⌘⇧R` | load it again without believing the cache |
| `⌘.` | stop loading |
| `⌘[` `⌘]` | back / forward through this tab's own history (also the ‹ › buttons) |
| `⌘,` | settings — `savoia://configuration`, in a tab like any other address |
| `⌘T` | new tab, at the very end, outside every group |
| `⌘⇧N` | new document — Markdown in a tab of its own |
| `⌘⇧P` | new private window — in the private profile (in-memory session, nothing recorded); File → Close Private Browsing forgets it |
| `⌘W` | close the tab |
| `⌘⇧T` | put the last closed tab back where it stood — ten deep, this run only |
| `⌘⇧]` `⌘⇧[` | next / previous tab, round the end (View ▸ Show Next Tab / Show Previous Tab). A folded group's tabs are skipped |
| `⌘1` … `⌘8` | that tab; `⌘9` the last one |
| `⌘S` | save — a document that has a file goes back to it; otherwise Save As |
| `⌘⇧S` | save as… — a document as `.md` / `.html` / `.pdf`, a page as `.html` / `.pdf` / `.txt`; the folder is remembered |
| `⌘⇧L` | translate the page |
| `⌥⌘A` | the accessibility overlay on / off (View ▸ Accessibility Overlay) ([accessibility.md](accessibility.md)) |
| `⌘F` | find on the page ([Find on page](#find-on-page-f)) |
| `⌘L` | focus the address field |
| `⌘E` | the assistant line: up and focused, or put away if it is already up |
| `⌘⇧E` | chats — `savoia://chats`, every conversation with an agent, as a tab (View ▸ Chats) |
| `⌘Y` | history of the current profile |
| `⌘D` | bookmark the page (again: remove the bookmark) |
| `⌘⌥B` | bookmarks, searchable by meaning |
| `⌘` + click a link | open it in a new tab behind this one. `⇧` and `⌘⇧` clicks do nothing at all: WebKit never passes them on ([links.md](links.md)) |
| `⌘`-click `⇧`-click on a tab | pick tabs one by one / a run of them; the tab menu then acts on all the picked ones |

## Start page (a new tab)

| | |
|---|---|
| typing | completions: an address row when the input looks like one, then pages from the profile's history, then the engine's suggestions |
| `↑` `↓` | walk the rows |
| `↩` | open the selected row, or the raw input (address, or a search) |
| `Esc` | clear the field; on an empty field, let go of the caret. A click beside the field does the same |

## Address field (`⌘L`)

| | |
|---|---|
| `↩` | open the address, or search for the text |

## Find on page (`⌘F`)

Pushed above the page rather than drawn over it, so the field takes the keyboard. Matches are painted with the CSS
Custom Highlight API — nothing is written into the page's DOM.

| | |
|---|---|
| typing | searches as you type, case-insensitive, and lands on the first match |
| `↩` | next match, wrapping to the first past the last |
| `⇧↩` | previous match, wrapping the other way |
| `Esc` | close — the query is kept, the highlights are not; `⌘F` again picks up where it left off |

## Bookmarks (`⌘⌥B`)

| | |
|---|---|
| typing | search by meaning across the profile's (or every profile's) saved pages; the matching passage under each |
| `↑` `↓` | walk the rows — from the field, without clicking into the list first (`walksRows`) |
| `↩` | open the selected row (or the first) in a new tab |
| `⌘⌫` | remove the bookmark and its file, and land on the row that takes its place |
| `⌫` | the same, while the list itself has the focus |
| `Esc` | close |

## History (`⌘Y`)

| | |
|---|---|
| typing | filter by title and address |
| `↑` `↓` | walk the rows (`walksRows`) |
| `↩` | open the selected visit (or the first match) in a new tab |
| `⌘⌫` | forget the selected visit, and land on the row that takes its place |
| `⌫` | the same, while the list itself has the focus |
| `Esc` | close |

## Assistant line (`⌘E`)

| | |
|---|---|
| `↩` | ask; the answer streams under the line. On an empty line, apply the answer |
| `←` `→` | walk the verb chips beside a field or a selection (`chipKey`, only while the field is empty) |
| `/` | the verbs as a list, narrowed by what follows; with an agent chosen, matching chats as well (`chatMatches`) |
| `↑` `↓` | after `/`, walk the chats — into the list from the field's side, out again the other way (`chatKey`) |
| `⇥` | after `/`, lock the first verb into a chip |
| `⌘⌫` | on an empty field, take the verb chip, or the chat chip, off |
| `Esc` | put the line away |

## Chat tab (`savoia://chat/<id>`)

| | |
|---|---|
| `↩` | send |
| `⌘↩` | send (also while the field is multi-line) |

## Notes

- **A letter binding answers to the key's position as well as to what is printed on it.** `⌥⇧P` on a Russian layout
  reports «з» from `charactersIgnoringModifiers`. `KeyBinding.Key.letter` matches either the US key code or the
  character, so the letters work on a Cyrillic layout (by position) and on Dvorak (by letter).
- **Nothing in the table answers outside Savoia's own window.** A sheet, a popover and WebKit's full-screen video are
  `KeyContext.Window.elsewhere`.
- **Nothing in the `⌘` table greys out, and the reason is a bug worth knowing.** SwiftUI decides `.disabled` when a
  `Commands` body is built, and a body reading model state is *not* rebuilt when that state changes — so an item
  disabled on `canGoBack` stays disabled after you navigate, and a disabled item does not answer its key equivalent
  either. The tab is read inside the action instead. `.disabled` on a `@FocusedValue` is fine.
- **The `⌘` keys are measured with a page focused.** `KeySelfTest.menuKeys` makes the `WKWebView` first responder by
  hand and then posts `⌘[` `⌘]` `⌘R`, watching the back list and a mark left inside the page.
- **`⌃←` and `⌃→` never reach Savoia, and no application can have them.** They are Mission Control's *Move left/right
  a space* — symbolic hotkeys 79 and 80, on by default. That is why the ring's arrows are written `⌃⇧←` / `⌃⇧→`
  above. System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control turns the pair off.
- **A key the system owns tests green.** `KeySelfTest` posts with `NSApp.postEvent`, straight into the app's own
  queue, past everything the WindowServer would have taken. `SAVOIA_UI_DEBUG=1` printing *nothing* for a press is
  the tell, because a key that arrives and is declined still prints.
- **`SAVOIA_UI_DEBUG=1` prints a line per key** — the chord, the context it landed in, and who took it.
  **`SAVOIA_KEY_SELFTEST=1`** prints the whole matrix at launch, then posts the ring's and the menu's keys.
