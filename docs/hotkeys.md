# Hotkeys

Every key binding in six, in one place. `⌥` is the layout's modifier; `⌘` bindings are the browser's own. Each
row is backed by a key monitor, a menu item or a view — the file is named so nothing here can drift from the code:
**`KeyBindings` in `six/Input/`** for everything a menu cannot keep, `ViewCommands` / `HistoryCommands` /
`BookmarkCommands` in `six/Views/MacCommands.swift`, the File menu in `six/sixApp.swift`, `FileCommands` in
`six/Documents/Export.swift`, the rest in `six/Views/`.

**This file is checked against the code.** `KeyBindings` is in `SixCore` — a binding is a key's name, the
modifiers a hand can hold, where it may answer and what it does, none of which is AppKit's business — and
`Tests/SixCoreTests/KeyBindingsTests.swift` reads *this* file and asks the table about it in both directions:
every binding has to be written down here, and every key the row and ring tables below promise has to resolve
to one. The line above has been in this file since it was written; it is enforced from `b7dc8da` on. On its
first run the check found `⌤` bound and undocumented, and a mutation test confirmed it catches the other
direction — which is the one that would have caught `Esc` in the ring going quiet for a year.

The split is worth stating once: **`⌘` belongs to the menu bar** — which shows the key, greys it out when it cannot
be pressed, and is where a person looks for it — and **everything else belongs to `KeyBindings`**, one array walked by
one `NSEvent` monitor (`KeyRouter`). A binding is in the table when a menu item cannot deliver it: a first-responder
`WKWebView` answers a key equivalent before the menu bar is asked, and keeps `⌥←` for word movement.

## The row (`⌥` — `KeyBindings`, scope `.row`)

Not a menu. These used to be a **Layout** menu of eleven items, ten of which were an arrow key, and that menu
could not make them work anyway: a first-responder `WKWebView` answers a key equivalent before the menu bar sees
it and keeps `⌥←` / `⌥→` for word movement, so after clicking into a page the layout keys went quiet. They come
through a local `NSEvent` monitor now (`KeyRouter`).

**Every key here is offered to the page first** (`KeyBinding.Precedence.pageFirst`). `⌥` has work of its own on a
Mac before six gives it any — `StandardKeyBinding.dict` makes the arrows word and paragraph movement, the letters
type «∑ ß ø ç», WebKit pages a scrollable page with `⌥↑` / `⌥↓`, and a web app may bind anything it likes (Google
Sheets walks its sheets with `⌥↑` / `⌥↓`). Nobody can know in advance which of those the thing in front of you
wants — a page's `addEventListener` cannot be enumerated from outside — so six does what Chrome and Firefox do
for every shortcut they do not reserve: the key goes to the page, and six answers only if the page hands it
back. WebKit already does the handing back. A key the page did not handle — no `preventDefault`, no caret moved,
nothing scrolled, nothing typed — is sent again through `NSApp.sendEvent` (`WebViewImpl::doneWithKeyEvent`,
which is how the menu bar gets the `⌘` keys a page leaves alone), and that second delivery passes through the
same local monitor. `KeyRouter` remembers the key it let through by timestamp and key code and answers it when it
comes back. Measured, by `SIX_KEY_SELFTEST=page` (`KeySelfTestPage.swift`):

| where | `⌥←` | `⌥↓` | `⌥W` |
|---|---|---|---|
| a page that does not scroll | row | row | row |
| a page that scrolls | — | **the page**, by a screen — at its bottom edge too, so holding it never falls through to the next workspace | row |
| a field on the page, with text | **the page** (word) | **the page** | **the page** («∑») |
| an empty field on the page | **the page** — WebKit keeps it though nothing moves | **the page** | **the page** |
| a page with its own `keydown` handler for the key | **the page** | **the page** | **the page** |

Six's own fields (the address, `⌘E`, the start page, a document) cannot hand anything back, so for them the router
decides on the first pass (`KeyBinding.yieldsToCaret(in:)`): **every arrow goes to a field with any text in it**,
and every `⌥`+letter goes to any field at all, empty included. It used to be per caret — `⌥←` yielded only while
there was a word behind the caret — and that was a trap: holding `⌥←` walked the caret home and one press later
changed the *window*. On the empty field a fresh window opens with the arrows move nothing, and there they still
walk the row. The `.keyboardShortcut`s the View and File menus show for `⌥W` `⌥S` `⌥O` `⌥⇧T` `⌥⇧H` `⌥⇧P` do not
take the letter from a field first — measured, the field gets its «∑».

`⌘⇧C` is the exception in the other direction: reserved, although Google Docs binds it for a word count. A `⌘` chord
offered to a focused page never came back through the monitor — measured, nothing copied — so it is taken first,
as it always was.

The cost is the obvious one: on a page that scrolls, `⌥↑` / `⌥↓` are the page's, and a page that swallows every key
(a game, a remote desktop, Figma) keeps them all. That is what the reserved keys below are for.

| | |
|---|---|
| `⌥←` `⌥→` | focus the window left / right |
| `⌥⇧←` `⌥⇧→` | move the window left / right |
| `⌥Home` `⌥End` | first / last window in the row (also First Window / Last Window in the strip's own menu) |
| `⌥↑` `⌥↓` | focus the workspace above / below |
| `⌥⇧↑` `⌥⇧↓` | move the window to the workspace above / below (and follow it) — the whole column, so a split travels as the pair it is |
| `⌥W` | full width — the page fills the window under the top bar; again to leave (also View ▸ Full Width, and the button beside the profile) |
| `⌥S` | split — the window next along comes in beside this one, sharing its column; again to put them back in the row (also View ▸ Split, and the strip's own menu). Both halves are windows in their own right: `⌥←` `⌥→` walk into one and then out to the next column, and closing one leaves the other filling the column. Moving is where they are one thing — `⌥⇧↑` `⌥⇧↓` and a drag in the overview take the pair, and this key is the way apart ([layout.md](layout.md#two-windows-in-one-column)) |
| `⌥O` | overview on / off; `Esc` also leaves it (also View ▸ Overview, and the button at the right of the top bar). In the overview a click on a card flies to it, a card's × closes it, and the dashed place at the end of a row opens a window there |
| `⌥C` | centre the focused window (on by default) — off means the row moves as little as possible. The switch is on `six://configuration` ▸ Windows |
| `⌥` + vertical scroll | one workspace per gesture |
| `⌥` + horizontal scroll | a window per push while centring is on — as many as the hand asks for, one per 55 pt of travel; free panning with `⌥C` off |

Where the row runs out, the gesture is answered rather than ignored: the edge pushed into lights up
in the profile's colour and the rubber band gives less, and nothing moves, because there is nothing
that way ([layout.md](layout.md#the-ends-of-the-row)).

## Reserved (`⌃⌥` — `KeyBindings.reservedRow`, macOS only)

The row's navigation again, taken **before** the page or a field sees it (`Precedence.reserved`). `⌃⌥` is the one
pair of modifiers that means nothing to a Mac: `StandardKeyBinding.dict` binds `⌃⌥B`, `⌃⌥F` and `⌃⌥⌫` and no arrow,
`com.apple.symbolichotkeys` has none of it, and it types no character — so these can be taken first without taking
anything from anyone. The way off a field with text in it, and out of a page that keeps every key.

| | |
|---|---|
| `⌃⌥←` `⌃⌥→` | focus the window left / right |
| `⌃⌥⇧←` `⌃⌥⇧→` | move the window left / right |
| `⌃⌥↑` `⌃⌥↓` | focus the workspace above / below |
| `⌃⌥⇧↑` `⌃⌥⇧↓` | move the window to the workspace above / below |
| `⌃⌥O` | overview on / off |

The Mac's alone. `StripKeyLookup` reads this table on Windows, where `Ctrl+Alt` is AltGr and types half of a Polish
keyboard; the Linux front has its own `<Alt>` shortcuts. Both fronts still have the conflict this section exists
for — `Alt+←` / `Alt+→` are Back and Forward in every browser there — see [todo.md](todo.md).
VoiceOver's `VO` keys are `⌃⌥` too; with VoiceOver on, these belong to it.

## Flying between windows (`⌃` — `KeyBindings`, scope `.switcher`)

| | |
|---|---|
| `⌃Tab` | hold `⌃`: the windows in the row in front of you, as pictures, in the order they were last looked at, the one you would land on in the middle. Each press steps one along the ring; letting `⌃` go flies there |
| `⌃⇧Tab` | the same, the other way |
| `⌃⇧←` `⌃⇧→` | one card along the row, the way it is drawn — which is not `⌃Tab`'s step, and has not been since the row started being drawn along the row ([layout.md](layout.md#⌃tab--the-order-the-windows-were-looked-at)). `⌥` instead of `⇧` does the same: the row's arrows are bound for **any** modifiers, and the ⇧ is there to get past macOS |
| `↩` `⌤` | fly now, without waiting for `⌃` to come up |
| `Esc` | let go of the ring without going anywhere |

While the ring is up it is on top of everything else in the window: its own keys answer first, and any other key
lands the flight and goes on to whatever it was meant for. **Including over a caret** — an arrow belongs to a focused
field while there is text to walk over, and the open ring is the one thing that outranks that
(`KeyBinding.yieldsToCaret(in:)`). Without the exception `⌃→` over a ring opened while the address field had the
caret moved the caret, and read as an arrow that did nothing at all.

The row's order and this one are different questions: `⌥←` / `⌥→` walk the windows where they stand,
`⌃Tab` walks them in the order they were used, so a single press is a toggle between the last two.
One row's windows only — the workspace on screen — and this run only. `⌥↑` / `⌥↓` are what move between workspaces, and they say where they are going.

## Browser (`⌘`)

| | |
|---|---|
| `⌘R` | load the page again (also the ⟳ button beside the address) |
| `⌘⇧R` | load it again without believing the cache — everything asked of the network afresh |
| `⌘.` | stop loading |
| `⌘[` `⌘]` | back / forward through this window's own history (also the ‹ › buttons) |
| `⌘,` | settings — `six://configuration`, in a column of the row like any other address |
| `⌘T` | new window in the row, right of the focused one |
| `⌘⇧N` | new document — a Markdown column next to the pages (edit / preview in the top bar, where its address would be) |
| `⌘⇧P` | new private window — in the private profile (created on the first press; in-memory session, nothing recorded); File → Close Private Browsing forgets it |
| `⌘W` | close the focused window |
| `⌘⇧T` | put the last closed window back where it stood, showing what it showed — ten deep, this run only. A private window is not on the list, and neither is one that never showed anything |
| `⌘S` | save — a document that has a file goes back to it; otherwise Save As |
| `⌘⇧S` | save as… — a document as `.md` / `.html` / `.pdf`, a page as `.html` / `.pdf` / `.txt`; the folder is remembered |
| `⌥⇧H` | highlight the selection on the page; it comes back when the page is opened again (File → Remove Highlights on This Page to clear) |
| `⌥⇧P` | the focused window's video into the floating picture-in-picture player, and out of it again. WebKit's own player, above every other application, and it keeps playing when the window is scrolled out of the row — the page behind it is never given back for the live-page budget while it is up ([layout.md](layout.md#picture-in-picture)) |
| `⌘⇧C` | copy the address of the window you are reading, whole, as it would be pasted — the field shows a tick (Edit ▸ Copy Address). Arc's Copy URL, and `⌃⇧C` on the fronts with no `⌘` (`KeyBindings.copyAddressChord`). Nothing to copy on a start page, a document or an app window, and there the key is left to whatever else wants it. A **table row** and not just the menu item, unlike every other `⌘` key here: it is pressed with the page focused, and a focused `WKWebView` answers a key equivalent before the menu bar is asked. `⌘C` stays the page's — that one is the selection |
| `⌘F` | find on the page in front of you — searches the page's own JavaScript, since `WebPage` carries no find API of its own and `WKWebView`'s is an async completion-handler with no menu (also View ▸ Find on Page…) |
| `⌘L` | focus the address field |
| `⌘E` | the assistant line: up and focused, or put away if it is already up |
| `⌘⇧E` | chats — `six://chats`, every conversation with an agent, as a column (View ▸ Chats) |
| `⌘Y` | history of the current profile |
| `⌘D` | bookmark the focused page (again: remove the bookmark) |
| `⌘⌥B` | bookmarks, searchable by meaning |
| `⌘` + click a link | open it in a new window right of this one, behind — the row leans right for a moment to show it. `⇧` and `⌘⇧` clicks do nothing at all: WebKit never passes them on, and a middle click arrives indistinguishable from a plain one ([links.md](links.md)) |
| `Esc` | close the overview; otherwise the page's own |
| `↩` `⌤` | in the overview, fly into the focused window — what a click on its card does. Scoped to the overview (`KeyBinding.Scope.overview`), so outside it the key never reaches the table; a workspace being renamed on its plate keeps it |

## Start page (a new window)

| | |
|---|---|
| typing | completions: an address row when the input looks like one, then pages from the profile's history, then the engine's suggestions |
| `↑` `↓` | walk the rows |
| `↩` | open the selected row, or the raw input (address, or a search) |
| `Esc` | clear the field; on an empty field, let go of the caret — so the `⌥` keys reach the row again. A click beside the field does the same |

## Address field (`⌘L`)

| | |
|---|---|
| `↩` | open the address, or search for the text |

## Find on page (`⌘F`)

A sibling of the web view in the column's stack, like `TranslateBar` and `PermissionBar` and for the
same reason: pushed above the page rather than drawn over it, so the field takes the keyboard without
going through `HostedOverlay`. Matches are painted with the CSS Custom Highlight API — nothing is
written into the page's DOM.

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

## Chat window (`six://chat/<id>`)

| | |
|---|---|
| `↩` | send |
| `⌘↩` | send (also while the field is multi-line) |

The agent panel is not reachable from the interface at the moment (`toggleAgentPanel` is published and nothing reads
it); its keys were the chat window's.

## Overview

| | |
|---|---|
| `↩` while renaming a workspace | commit the name |

## Notes

- **A letter binding answers to the key's position as well as to what is printed on it.** `⌥W` on a Russian layout
  reports «ц» from `charactersIgnoringModifiers`; matching only that is why `⌥W` / `⌥O` / `⌥C` were dead for anyone
  not typing in Latin. `KeyBinding.Key.letter` matches either the US key code or the character, so the three work on
  a Cyrillic layout (by position) and on Dvorak (by letter).
- `⌥W` / `⌥S` / `⌥O` / `⌥C` / `⌥⇧T` / `⌥⇧H` / `⌥⇧P` type their characters in any field, on a page or six's own; they
  are the row's everywhere else. `SIX_UI_DEBUG=1` says which: `offered to the page first` and then either nothing
  (the page kept it) or `…, after the page`.
- **Nothing in the table answers outside six's own window.** A sheet, a popover and WebKit's full-screen video are
  `KeyContext.Window.elsewhere`, and there `⎋` closes the sheet instead of the overview behind it and `⌥O` does
  nothing at all.
- To move the whole layout set to another modifier, change the `.exactly(.option)` rows in `KeyBindings.table` — the
  keys are read there and nowhere else. The `.keyboardShortcut`s left in `ViewCommands` and `FileCommands` (`⌥W`,
  `⌥O`, `⌥⇧T`, `⌥⇧H`, `⌥⇧P`) are for display and for the pointer; the router answers the key before the menu can.
- **Nothing in the `⌘` table greys out, and the reason is a bug worth knowing.** SwiftUI decides
  `.disabled` when a `Commands` body is built, and a body reading model state is *not* rebuilt when
  that state changes — so an item disabled on `canGoBack` stays disabled after you navigate, and a
  disabled item does not answer its key equivalent either. `⌘[` was dead on arrival for exactly that,
  with a run each way to prove it was the modifier and not the action. The window is read inside the
  action instead, and a key pressed where it has nothing to do does nothing. `.disabled` on a
  `@FocusedValue` is fine — that is the one thing a `Commands` body does get rebuilt for.
- **The `⌘` keys were measured with a page focused, not reasoned about.** `KeySelfTest.menuKeys`
  makes the `WKWebView` first responder by hand and then posts `⌘[` `⌘]` `⌘R`, watching the back list
  and a mark left inside the page. WebKit takes `⌥←` in front of the menu bar; it does not take
  these.
- **The keyboard follows the row's focus, and that had to be made to happen.** `⌥→` moves the focus; AppKit's first
  responder stayed where a click had put it, so the keys went on reaching the window you had walked away from
  ([layout.md](layout.md#the-keyboard-follows-the-focus)). It is never taken off a text field — `⌘L` and `⌘E` are
  left by keystroke — so nothing here eats what you were typing.
- **`⌃←` and `⌃→` never reach six, and no application can have them.** They are Mission Control's *Move
  left/right a space* — symbolic hotkeys 79 and 80, on by default — and the WindowServer takes them
  before any app's event monitor. That is why the ring's arrows are written `⌃⇧←` / `⌃⇧→` above: the
  binding matches any modifiers, so one extra key is enough to get the event delivered. System
  Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control turns the pair off for anyone who would
  rather have the bare arrows. **This is a Mac tax and only a Mac tax** — the table is `SixCore`'s and
  nothing on Linux or Windows takes `⌃←`, so the bare arrows work on those fronts. Three keys to page
  a carousel is a bad answer wherever it is written down; [todo.md](todo.md) keeps it open.
- **A key the system owns tests green.** `KeySelfTest` posts with `NSApp.postEvent`, which puts the
  event straight into the app's own queue — past everything the WindowServer would have taken. So a
  binding can be measured working, card index and all, and do nothing whatsoever in the hand. When a
  key is reported dead and the table says it is bound, check the system's own shortcuts before the
  router; `SIX_UI_DEBUG=1` printing *nothing* for a press is the tell, because a key that arrives and
  is declined still prints.
- **`SIX_UI_DEBUG=1` prints a line per key** — the chord, the context it landed in, and who took it. **`SIX_KEY_SELFTEST=1`**
  prints the whole matrix at launch: every binding against every context, which is how a binding that goes quiet
  somewhere is found without pressing anything (`KeySelfTest`; this Mac cannot press its own keys, see AGENTS.md).
