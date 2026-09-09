# The niri layout

Modelled on [niri](https://github.com/YaLTeR/niri). There are no tabs and no sidebar.

- A page is a **column**: a full-height window that is nothing but the page, edge to edge inside a rounded card.
  Everything that used to be drawn on it — the lock, the shield, the address, the title — is in the top bar, for the
  focused window only, because a rail of a dozen windows does not want a dozen address fields. The `×` is the one
  thing that stayed with the window: it sits on the card's top right corner, invisible until the pointer is on it.
- Columns sit left to right on an endlessly scrollable **rail**. One rail is a **workspace**.
- Workspaces are stacked **vertically**; exactly one is on screen. Each profile has its own stack.
- A workspace can be **named** (double-click its plate in the overview). Naming is optional; an unnamed one is just
  "Workspace N". An unnamed workspace disappears the moment its last window does — same as niri. A named one is
  **asked about** first: *Delete the workspace "X"?*, once, at that moment, and it goes or stands by the answer.

*The interface calls it the rail; the code calls it a strip — `NiriStrip`, `allStrips`, `strip.state`, the
`StripState` JSON, the Kotlin beside it and the golden geometry those two agree on. That name is a wire format shared
with the Linux and Android fronts, so it stays where it is and the rename stopped at the words a person reads. Every
`strip` below is the type, every "rail" the thing on screen.*

*`NiriLayout` is the one file two front ends share. It has no platform in it — `CGFloat`, `CGRect`,
`CGSize` and nothing else — so the GTK front computes its columns from the same `columnFrames()` and
inherits the same promises. Those promises are the repository's first tests
(`Tests/SixCoreTests/NiriLayoutGeometryTests.swift`), written against the intent stated below rather
than against the numbers it happens to produce, because that is what would silently desynchronise the
two. See [linux.md](linux.md).*

## Model — `six/Niri/NiriLayout.swift`

```
NiriStrip     workspaces: [NiriWorkspace], focus: Int      // one per profile
NiriWorkspace name: String, columns: [NiriColumn], focus: Int, viewOffset: CGFloat
NiriColumn    tabID: UUID                                 // points at a BrowserTab
```

Every mutation goes through `mutate { }`, which runs `normalize` afterwards, so the invariants hold by construction:

- **Dynamic workspaces.** Exactly one empty workspace is kept at the bottom; empty ones in between are dropped, unless
  they are named. The trailing workspace keeps its identity across the prune, so focus survives it.
- Column focus stays in range, and `viewOffset` stays clamped.

**An empty rail is a state, not an accident.** Closing the last window of a profile leaves the strip empty and opens
nothing in its place: the workspace draws its own offer — **New Window**, and `or ⌘T` under it — and that is the same
thing a workspace further down has always shown when it was emptied. The window `⌘W` used to conjure up was one
nobody had asked for, and it made the first workspace behave unlike every other. The same rule holds for a profile
switched to with an empty rail (`selectProfile`) and for a relaunch that restores one (`BrowserState.init`); only a
browser with nothing to restore opens the first window itself, and so does a profile just created.

### A row is drawn by identity, never by its number

`WorkspaceView` looks its own place in the strip up by `workspace.id` and draws nothing when the strip no longer has
it. That is not defensive tidiness: a row is removed with an animation, so it stays in the view tree for the length
of its transition, and by then the index it was built with names the row that moved up into its place. A dying row
that read the strip by that number drew the *next* row's windows — and a window is a `WebView` over a `WebPage`, of
which WebKit allows exactly one, so the second view trapped in `makeViewProvider` (`EXC_BREAKPOINT`) and took the
browser down. Closing the last window of workspace 1 while workspace 2 still held any was enough, every time.

It is the same trap `NiriLayout.unanimated` was written for, from the other side: there a window changed rows, here a
row went out from under a window. Anything that draws a page from a *position* in the strip has to resolve that
position at the moment it draws, against the strip as it is now.

### A named workspace that runs out of windows

Naming used to make a row immortal — niri's rule, and fine for as long as naming one was something only a person did.
It isn't: `workspaceIndex(named:createIfMissing:)` is called by every deep-research run (named after the question) and
by the MCP tools (`open_window(workspace: "notes")`), so a browser that answers questions for a living silts up with
empty rows carrying last week's questions.

The rule is now the same for every named row, whoever the name came from, and the difference is a question:

- `askBeforeRemoving` runs wherever a column leaves a row — `removeColumn`, both `moveColumn`s, `commitColumnDrag` —
  and queues a `NiriWorkspaceRemoval` (workspace id, name, profile) when that row is left empty *and* named. An
  unnamed row is never queued: it disappears as it always has, silently, a dozen times a day.
- `workspaceToRemove` is the head of the queue and what the front draws (`WorkspaceRemovalDialog`, on both the Mac's
  `ContentView` and `PhoneContentView`). `removeWorkspace(_:)` is yes, `keepWorkspace(_:)` is no, and dismissing the
  dialog any other way is a no — never an unanswered question read as consent.
- A **queue** and not one at a time: closing a profile or clearing a rail can empty several rows, and a question that
  overwrote another would delete a workspace nobody was asked about. `removeProfile` drops the questions belonging to
  a profile being deleted whole, and `prunePendingRemovals` (after every `mutate`) drops any whose row has been filled
  again or has gone — a question is only worth asking while it is still true.

Asking is deliberately a *transition* and not part of `normalize`: normalize cannot tell a row that has become empty
from one that was made a moment ago, and every caller of `workspaceIndex(named:createIfMissing:)` creates a named
empty row and fills it on the next line. Nothing about the stored shape changed, so `state.json` is unaffected and
Android — which has the model ported line for line but no dialog yet — keeps a named empty row standing, as every
front did before this. The plate's **Delete Workspace** (overview, right-click a name) is the way out for a row that
was already standing empty before the question existed.

## Geometry

**Everything here is a fraction of the viewport, never a pixel count** — the layout has to read the same on a laptop
and on a 5K panel. Gaps are `gapFraction` (1 % of the width), the vertical space between workspaces is
`workspaceGapFraction` (2 % of the height). The absolute numbers left in the file are floors (`minimumGap`, the 280 pt
minimum column) that only matter in a tiny window. Control metrics — title bar heights, button sizes, corner radii —
deliberately stay in points, since text and controls don't scale with the screen either.

**There is one width.** `columnWidth` is the viewport less its outer gaps, so exactly one window fits on the screen and
the next one starts a screen away. niri's `preset-column-widths` — halves, two thirds, a rail of mixed widths — went,
along with the compact-width toggle that widened one window against the rest: a browser window at two thirds of a
screen is a page with a hole beside it, and choosing between four fractions of one is a decision nobody asked for.
What is left is which of two ways a window is shown, and a rail narrower than the viewport is centred instead of
pinned left.

The focused column is **centred** by default (niri's `center-focused-column`), so both neighbours peek in by the same
amount; while centring is on the rail may scroll until the first/last column reaches the middle, which is what lets
every column get there. `⌥C` turns it off, and focus then moves the view as little as possible — `scrollFocusIntoView`
scrolls only until the focused column is fully visible. The choice persists in `UserDefaults`.

Offsets are stored per workspace but the geometry that produced them is global, so a rail that was laid out at another
viewport — the other profile's, or one restored from `state.json` — would come back scrolled off centre. `recenterStrips`
puts every rail back under its focused window whenever the viewport or `⌥C` changes, and switching `activeProfileID`
does the same for the rail coming on screen.

Only columns of the workspace on screen, within one viewport-width of it, get a real `WebView`; the rest render as
cards (`ColumnPlaceholder`), so a long rail stays cheap. Whether a column *has* a page to mount at all is a separate
question and the live-page budget's — see [architecture.md](architecture.md#live-pages): the rail pins what is on
screen and builds only the focused window, once the focus has settled, so walking the rail loads the window you stop
at rather than every window you pass. In the overview nothing is mounted and nothing is built; every window there is a
card, and a card is its title on the rail and the last picture of the page in the overview.

Restricting live views to the *current* workspace is not only about cost: a web view is a real AppKit view, SwiftUI's
clipping does not reach it, and one parked a screen above still answers the mouse over the top bar — which is how
clicking a button up there could fly you to the workspace above. Off screen, it must not exist. The neighbours come
back while a gesture is peeking at them (`verticalPreview != 0`).

The same is true of everything else a workspace off screen contains, which is the other half of that bug: cards and
their shadows reach into the top bar's band too — how far depends on the window's size, since the gaps are fractions of
the viewport — and that is enough to take a click off a button there, intermittently. So a workspace that is not the
current one answers nothing at all (`allowsHitTesting`), unless the overview is open and it really is on screen; and
the top bar is `zIndex`-ed in front of the rail, since they are siblings in a stack and the rail is hit-tested after
it.

## Gestures — `six/Niri/NiriScrollMonitor.swift`

*This section is AppKit's. The GTK front reaches the same gestures through a
`GtkEventControllerScroll` in the capture phase, where the boundaries of a gesture are explicit
rather than inferred — which is one of the few places the second front had an easier time.*


A local `NSEvent` monitor sees scroll events before WebKit does. It acts on them when `⌥` is held, when the overview is
open, or — unmodified — when the pointer is over the layout's own chrome. "Chrome" is decided by hit-testing the event
point: anything inside a `WKWebView`, `NSScrollView` or `NSTextView` keeps its own scrolling, everything else (title
bars, gaps, background) drives the layout.

Without `⌥` the pointer must also be **inside the rail** (`stripFrame`, published by the view in SwiftUI's window
coordinates and flipped in the monitor, which measures from the bottom of the window). The top bar is chrome too, and
letting it drive the layout made clicking one of its buttons a gamble: a hair of finger travel on a trackpad switched
the workspace under the cursor. Held `⌥` still works anywhere — then it is an explicit layout gesture.

Vertical is **one workspace per gesture**: deltas accumulate into a rubber-band preview (`verticalPreview`), crossing
the threshold commits the switch, and the rest of the gesture — trackpad momentum included — is swallowed, so a flick
never skips two. Discrete mouse wheels have no gesture phase and are throttled by time instead.

Horizontal works the same way **while centring is on**: one window per gesture, with a `horizontalPreview` rubber band
below the threshold. The rail then has no free resting position — `panStrip` refuses to move it at all, so no gesture
can leave a window sitting half-way. With centring off (`⌥C`) horizontal scrolling pans the rail freely, and on
release focus snaps to the column nearest the middle and scrolls it fully into view.

Tuning lives at the top of the file: `threshold` (55 pt), `minimumCommitInterval` (0.28 s), `idleReset` (0.25 s).

## The ends of the rail

A rail is finite in both directions and a stack of workspaces is finite in one, so every gesture that
walks them has a way of asking for something that is not there. It used to be answered with nothing at
all: the strip did not move, the key gave nothing back, and the honest reading of that is *the gesture
was lost*, not *there is nothing that way*.

`NiriLayout` answers instead. The edge that was pushed into lights up — `wall` says which of the four
it is, `wallGlow` how brightly (0…1) — and the rail still does not move, because that is the thing
being said. Two ways in:

- **`hitWall(edge)`** — a step that had nowhere to go (`focusColumn`, `focusWorkspace`). Full
  brightness, held for a beat, then half a second of fading.
- **`pushWall(edge, by:)`** — a gesture leaning on that edge, from `previewColumn` / `previewWorkspace`
  and from a free pan that clamped. The light follows the finger and lets go with it, un-animated,
  because it *is* the finger's position; it reaches full at `wallPush` (19 pt — `threshold` through
  the rubber band's 0.35, which is the whole travel a gesture has before it commits).

The rubber band gives less at a wall, too: `wallResistance` (0.4) of what it would give where there is
a window behind the edge. That is the other half of the sentence, and the half a hand feels rather
than sees. Both live in the model rather than in the view, so a second front end draws the same
answer — [linux.md](linux.md).

Deliberately not a bounce and not a sound. A bounce is the rail moving, and the one thing that has to
stay true here is that it did not. The drawing is `StripWalls` in `NiriStripView`: a band of the
profile's colour along that edge, 5.5 % of the viewport deep, fading out towards both corners so it
reads as light caught on an edge rather than as a border the window grew.

## ⌃Tab — the order the windows were looked at

The rail is where windows *are*; `WindowSwitcher` is where they have *been*. The window you want next
is usually the one you just came from, and on a rail of a dozen that one can be six windows away in
either direction — so `⌥←` / `⌥→` walk the rail and `⌃Tab` walks the memory, the same division as
`⌥Tab` and the workspace keys in any tiling WM.

- Recency is taken in `BrowserState.syncSelection`, the one place every focus change ends, so a rail
  walked with `⌥→` is a rail whose windows have been looked at. This run only, like the list `⌘⇧T`
  reopens from.
- The ring is fixed when the switch opens and does not reorder while it is held — a list that resorted
  itself under the key would move the window you were aiming at — and it wraps, because a ring has no
  ends to hit. Windows never focused this run (restored from the snapshot) follow in rail order.
- **A stop is a column, not a window.** Two windows sharing one are both on screen at once, so a ring
  that stopped at each of them in turn would be asking you to choose between two halves of the view
  you are already looking at. `WindowSwitcher.open` takes a `column` function and collapses the halves
  *after* sorting by memory, so the half that survives is the one looked at more recently and landing
  puts the focus back in it. The card draws the pair, the way it looks on the rail, with the half you
  would land in at full strength — measured by `KeySelfTest`: `ring 5, columns 5, windows 6`.
- A rail with **one** window on it opens a ring of one. The key has to answer: a press that gives
  nothing back cannot be told from a key that is not bound, or from a browser that has stopped
  listening, and this one is held down, so the nothing would last as long as the hand does. Only an
  empty rail refuses, and there the screen is already saying so in the middle.
- One **rail's** windows only: the focused workspace's columns, not the whole strip and certainly not
  another profile. A workspace is a place you went to on purpose and a profile is a browsing world with
  a history and logins of its own; a key that flew you out of either would be doing something much
  bigger than it looks, and `⌥↑` / `⌥↓` already move between workspaces while saying where they go.
- Nothing is loaded while it is walked: the cards are the pictures the overview already takes
  (`rememberViewState` for the window being read, `loadPictureIfNeeded` for the rest). The flight
  happens once, on `⌃` coming up, through `selectTab` and the usual switch animation.

The keys come through `KeyRouter` for the reason the `⌥` bindings do — a first-responder `WKWebView`
answers a key equivalent before the menu bar sees it — and for a second reason besides: the ring is
held open by a modifier, and only a `flagsChanged` ever says a modifier was let go of. While it is
open the ring's own bindings answer first — `Tab`, `⌃←` / `⌃→`, `↩` to fly now, `⎋` to let go — and
any other key ends the pass and is passed on, so nothing can leave the switcher standing (the app
losing focus mid-press, most of all). The panel is `WindowSwitcherOverlay`,
mounted on `ContentView` over the top bar as well as the rail, and it answers no mouse: it exists only
while a key is held, and a target that vanishes when you let go of a key is not a target.

## Clicking

A window that isn't focused is a target, not a page: the first click flies to it (and centres it) instead of reaching
the page. The catcher has to be an AppKit view — `WKWebView` is a real `NSView` and takes the click before any SwiftUI
overlay above it can — so `ClickCatcher` is an `NSViewRepresentable` laid over the web view of every unfocused column.
Title bars are SwiftUI and keep their own buttons working, so a background window's close or back button still takes
one click.

### The keyboard follows the focus

The rail's focus and AppKit's **first responder** are two different things, and they could disagree: `⌥→` moved the
accent border, the address field and everything else keyed off the selection, while the keys went on arriving in the
`WKWebView` a click had last given them to. So the arrow keys scrolled the window you had walked away from, and text
went into its text field. On a rail that is nearly invisible — the window you left is off the edge a moment later —
and in a split it is not: one half is visibly highlighted while what you type lands in the other, which is how it was
reported.

`WebViewResponder` closes it. SwiftUI has no handle on the `WKWebView` inside a `WebView` and there is no route from
a `WebPage` to it either, so every pane leaves one: a zero-size AppKit view mounted beside its own web view, which
finds it **by frame** — the pane's handle is given the pane's size, so its web view is the one whose middle lands
inside it. Walking the view tree for the nearest ancestor holding exactly one web view is the obvious way and it does
not work: SwiftUI mounts a `.background` in a layer of its own, and the first ancestor with any web view under it is
usually the one that has all of them.

Two things it deliberately does not do. It never takes the keyboard **off a text field** — `⌘L` and the `⌘K` line are
reached by keystroke and left by keystroke, and a rail that walked into the page under them would eat the next thing
typed (the same test the key router uses). And for a window with no page to give it to — a card, a start page, which
is SwiftUI and has no web view at all — it takes the keys off whatever had them rather than leaving them with a
window the rail is no longer looking at.

Measured by `KeySelfTest.splitKeyboard`, which needs a setup of its own and says why: two windows with real pages,
because a split of two start pages has nothing for a first responder to be, and the first version of the check
measured exactly that. Each line prints who holds the keys and whether that agrees with the rail —
`keys WebPageWebView 702pt 8FCCFAD6 (agrees)` — and ⌥→ has to carry it to the other half.

**The other half of a split is an unfocused window like any other**, so the rule holds there too: the first click
lands the focus on it and the second reaches the page. It is the one place the rule can be argued with — both halves
are on screen, live and readable, which is not the case the rule was written for — and it stands anyway, because
what makes the click cheap is what would make it wrong to skip: the address field, ⌘W, ⌘L and the assistant all
speak for the focused window, and a page that answered a click without becoming the focused one would leave every
one of them pointing at its neighbour.

## Filling the window

Two ways of showing a window, and the whole of what there is to choose:

| | | |
|---|---|---|
| — | **the rail** | the ordinary one: a window is the screen less its outer gaps, in a card with corners |
| `⌥W` | **full width** | the page fills the window under the top bar — no gaps, no card, no corners. Also the button in the top bar beside the profile, and View ▸ Full Width |

There were three. The third was a *fullscreen* (`NiriFill.screen`) that took the top bar with it and gave the page
every edge, with a bar of its own hiding at the top of the screen and `⎋` to leave. It went, and the whole apparatus
went with it — the mode, `⌥⇧F`, `showsFullscreen`, `FullscreenBar`, `exitFullscreen`. It was a second answer to the
question full width already answers, the difference between the two being one 40-point bar; it cost the address
field, and the only ways back were a key and a pointer thrown at the top of the screen. macOS fullscreen (the green
button) still does the thing people actually want from the word.

A page's own `requestFullscreen` — the button in a video player — is a third thing again, and the one place where
WebKit does not do it for you. `WebView.ElementFullscreenBehavior` defaults to `.automatic`, which on macOS means
*off*: the same default `WKPreferences.isElementFullscreenEnabled` has always had, the one Safari sets for itself.
Left alone, `video.requestFullscreen()` is rejected and the player's button does nothing at all — no error, no
window, nothing to see. The rail's `WebView` says `.webViewElementFullscreenBehavior(.enabled)`, and so does the
phone strip's. What WebKit then opens is a window of its own, with its own `⎋`; `KeyEvents` already knows to keep
its hands off it, by the class name.

Turning it on is only half of it, and the other half is a WebKit bug six has to reach around. With the modifier
alone the page does go fullscreen — `fullscreenState` reaches `inFullscreen`, the sound plays, the timer runs — and
draws **nothing**: a black screen the size of the display, given back unharmed on `⎋`. Twenty-five lines reproduce
it with no six in them, and the same page in a `WKWebView` behind an `NSViewRepresentable` is perfect, so what
differs is how the view is *held*. SwiftUI's `WebView` hosts it under Auto Layout; WebKit's fullscreen controller
moves it into a window of its own and sizes it by frame, where it arrives with no constraints, is laid out at
nothing, and leaves the backdrop showing. `PageElementFullscreen` swaps the hold for the duration —
`translatesAutoresizingMaskIntoConstraints` and an autoresizing mask from `enteringFullscreen` until the state
comes back — and hands the view to Auto Layout again after, because leaving it flipped is its own regression: the
rail goes on laying out with constraints the view no longer answers to. The write-up and the repro are in
[UPSTREAM.md](../UPSTREAM.md).

Full width is `NiriFill.window` on the layout — a mode, not per-window state. `fillsViewport` is what the geometry
asks, and it is false while the overview is open, so the overview keeps its gaps and title bars and the mode returns
when it closes. The rail goes on working underneath: `⌥←` `⌥→` walk from window to window and the next one arrives
filled too, so a workspace reads like a stack of pages.

The geometry is the ordinary one with two overrides: `gap` (and with it `outerGap`) is 0, and `columnWidth` is the
whole viewport rather than the viewport less those gaps. So the difference between the two is a gap and a corner
radius, never a fraction of the page. Every column being exactly one screen wide is what makes the alignment fall out
for free: centred or not, the resolved offset of the focused column lands on a whole multiple of the viewport. Changing
the mode changes every width, so `setFill` re-centres every rail, as `⌥C` and a resize do.

Switching is deliberately **not** animated, unlike everything else the layout does. Every switch resizes every live
page, and a web view changing size costs a hitch you can see — around 50 ms with three columns live. Running that
through the 0.34 s spring spreads the stutter over the whole animation instead of getting it over with: measured over
six switches, 20 dropped frames animated against 5 instant. (The neighbours stay live on purpose, so stepping to the
next full window shows a page rather than a card; that is what makes the third resize worth paying for.)

Leaving: the same key again, View ▸ Full Width, the right-click menu, or the button in the top bar. `⎋` deliberately
does not — full width is ordinary browsing, where a page's own `⎋` is worth more; the only thing `⎋` leaves is the
overview, and that one does come through the scroll monitor's key monitor rather than SwiftUI, because a page holds
the first responder and a key press would never reach the view hierarchy. WebKit's own full-screen window (a video
playing) is left alone, so `⎋` there still belongs to the video. Closing the last window of the workspace leaves full
width too — a blank wall with no chrome is a trap.

**Controls over a page have to be AppKit.** SwiftUI drawn over a `WKWebView` never sees the mouse (the reason
`ClickCatcher` exists), and with the window filled there is nothing *but* page under them. So the step chevrons are
hosted in `NSHostingView` (`HostedOverlay`) — which must be frame-driven (`sizingOptions = []`,
`translatesAutoresizingMaskIntoConstraints = true`), or it publishes its size into the window's constraints and the
update passes never settle.

The chevrons stand in the **gap beside the focused window** (`focusedColumnFrame`), not against the edge of the screen
where the neighbour peeking in is, and they are as narrow as that gap — a button wide enough to read comfortably is a
button covering the page next to it. Nothing is drawn there at rest, in either mode: the rail is windows and gaps, and
a chevron parked in every gap is chrome charged against every window in it. Invisible is not absent: a SwiftUI
button at zero opacity still answers the mouse, which is what makes the sliver its own hover target.

All of that is the **peek**, and it is a pointer idea: it is asked for by resting somewhere and answered by the rail
leaning over. A finger has nowhere to rest — it is touching or it is not — so the whole arrangement has a switch,
`BrowserState.peeksAtEdges` (`six://settings` ▸ Windows ▸ Peek at the Edges, stored in the settings table). Off, there is no lean and no outline: the
slivers are simply drawn where they stand, at a little under half, and do their job on the way in — which is what the
rail did before the peek existed, and the only thing that works without a pointer. It defaults on for macOS and off
everywhere else, and it is chrome rather than geometry, so it lives in `BrowserState` and not in `NiriLayout`: a second
front end inherits nothing it has to agree with.

Both jobs are **one button**, which matters for one case: walking the chevron to the end of the rail leaves the
pointer resting on a button that has just become a `+`. Two views would make that an exit and an entry, and the entry
would arm the `+` under a hand that never moved — the last click of a run would open a window nobody asked for. One
view keeps its identity, sees the change (`disarmed`), lets go of the peek and does nothing until it is hovered again.

What answers the mouse and what gets drawn are two different things. What is drawn is the glyph, and only the glyph —
no plate, border or shadow under it, because the rail has already leaned aside to answer and anything around the
glyph is a second, smaller answer sitting on top of the real one. It follows the peek rather than the pointer: a `+`
that arrived under a hand that never moved is disarmed, and drawing it would offer a window the next click would not
open. The **target** runs the whole height of the window beside it while the
lane is a gap — background costs nothing, and a target you cannot see
has to be one you cannot miss along the edge you are sweeping — and shrinks to a band around the middle once the
window is filled and the lane is over the page. It also reaches the **edge of the viewport exactly**, half a lane and
not one point more: with the window maximised the rail's edge is the screen's, and throwing the pointer at the wall is
how you find a sliver you cannot see. A target starting one point in is a target that wall never hits.

At either end of the rail the chevron gives way to a button that opens a window, and the one at the near end opens it
*before* the focused one (`NiriPlacement`) — the rail has no other way of growing backwards.

Resting on **either** button leans the whole rail aside (`edgeHover`, `edgeLean`) to show what is over there. For the
chevron that is the next window itself. For the `+` there is no window yet, so an outline of one stands in the room the
lean opens up (`newColumnFrame`, drawn only where there is nothing to step to). The lean and the outline carry the
message between them — *there is something over here*, *it does not exist yet* — and the glyph that fades in with the
lean, `‹ ›` or `+`, only names which of the two this is, the way the outline's dashed edge used to before it went
solid.

Three decisions hold it together. The lean goes exactly as far as the glance a window opening behind gets
(`peekAmount`, a fraction of the viewport) — one distance for all of them, because they are the same sentence, *there is
something over here*. It is deliberately *not* `horizontalPreview`: that band belongs to the scroll gesture, and a peek
held by the mouse has to survive one arriving. And `focusedColumnFrame` deliberately does not include it, so the button
does not slide out from under the pointer holding it.

## Two windows in one column

`⌥S` takes the window next along into the one you are reading: they share the column, side by side, and the rail is
one column shorter. `⌥S` again puts them back. Also **View ▸ Split**, the strip's context menu, the window's own
menu, and — in the overview — one window dropped onto another.

The rule everything else follows from is that **a column is still one screen's worth of rail**. A split changes what
is inside a column and nothing about where columns are: the two halves fill exactly the width one window would have
had, so the strip is as long as it was, the offsets still land, and every promise `columnFrames()` makes is
untouched. The gap between the halves (`paneGap`) is deliberately *half* the one between columns — at the same width
a split would read as two windows standing next to each other, and proximity is the whole of what says otherwise.

niri splits a column the other way: its windows stack vertically. That is right for terminals and wrong for pages —
a web page is tall, and two half-height ones are two pages nobody can read. Two is the ceiling for the same kind of
reason: three pages at a third of a screen each are three unreadable pages, and wanting more than two things at once
is the question the rail already answers.

**The two halves are windows, not panes of one window.** Each has its own border, its own `×`, its own progress
line; `⌥←` / `⌥→` walk into the near half before stepping to the next column, so every window on the rail is one
step from its neighbour whether or not it is sharing a column; `⌘W` closes one and leaves the other filling the
column; `⌥⇧↓` takes the focused half to the next workspace and leaves its neighbour where it stood. `⌥⇧→` inside a
split swaps the two halves, because one place along, inside a column, is the other side of it.

Both halves are *built*, and that is the one thing the live-page budget had to be told
([`LivePageCache.setVisible`](../six/Browser/LivePageCache.swift) takes a column and not a window): a split showing
a card in one half is a split that did not happen.

### The width changes in one step, and that is deliberate

A split changes how wide two **live** pages are, and WebKit lays a page out again at every width an animation passes
through. Animated, ⌥S walked two pages through eight widths in a tenth of a second — 1412, 1386, 938, 867, 773, 733,
709, 702 on a 5K panel — and at each step the page was laid out wider than the box it was in, which is a horizontal
scrollbar you can watch appear and go. Un-animated it is one resize, and the site takes its narrow layout at once.
The fill modes gave up their animation for the same reason ([above](#filling-the-window)); `BrowserState`'s
`plainLayoutChange` is where the split says so.

The animation was not in the layout, and finding that took three wrong fixes. `NiriLayout.unanimated` did nothing,
and neither did taking the split out of `animateLayout`: it was **`.animation(.easeOut, value: isFocused)` on the
card**. A value-scoped animation animates *every* change in the subtree it is attached to when its value changes, and
⌥S is the only thing in the rail that moves the focus and changes a window's width in the same breath. It lives on
the border it was written for now. The frame is pinned against an ambient animation at the call site as well
(`.animation(nil, value: frame.size)`), for the menu items that carry one; the **offset** keeps its animation,
because that is the rail scrolling and it is about motion.

### Making one with the pointer

In the overview, a window let go over the **middle half** of another joins it; over the quarter at either end, or in
the space between, it stands beside it as it always did (`NiriLayout.joinFraction`). By the time the cards are
centred on each other they are all but on top of one another, which is what a person means by putting one window on
another. It lands on the side it was held over, and a column that is already two is not a target.

The threshold is **wider to leave than to enter** (`joinRelease`). The two answers are a relayout of the whole row
apart, so a hand resting on the line between them flipped it back and forth with every tremor: one threshold is a
switch nobody can hold still.

Two things say what will happen before it does. The row opens the gap — the window being joined shows its other half,
empty, because the window that would fill it is in the air — and `DropSlot` draws the place itself: the profile's
colour, exactly the rectangle the window is about to occupy, taken from `arrangement` so it cannot disagree with the
row under it. The gap alone was not enough, which is worth knowing: a gap is the *absence* of a thing, and half a
column's absence beside a window reads as easily as a window that happens to be narrow. The outline is drawn **above
the carried card** and as a border with no fill, because a drop that joins has the pointer over the target's middle —
the card is sitting on top of its own destination and twice as wide as it, so an outline underneath is one you cannot
trust to be there.

### The identity a column keeps

`NiriColumn` has an `id` of its own, and that is not decoration. A split that loses a half is the same column with
one window left in it; a half taken out into a column of its own is a column that has just arrived. The view tree
has to be able to tell those apart, because a window is a `WebView` over a `WebPage`, of which WebKit allows exactly
one — identified by the window it held, as it was when it could only hold one, every split and unsplit looked like a
column leaving and another arriving, which is the trap `unanimated` exists for. It is why splitting is done inside
it, and why a window carried across the overview keeps its column's id all the way to the drop.

A column written before splits existed is a `tabID` and nothing else, so it decodes with the other halves at their
defaults; a relaunch after an update finds the rail it left.

## Picture-in-picture

`⌥⇧P`, View ▸ Picture in Picture, the same item in a window's own menu, and the button in WebKit's media controls:
the video leaves the page for a small window floating above every other application, and the page it left goes on
being an ordinary window on the rail. Scroll away from it, step to the workspace below, switch profiles — the player
stays where it was put and keeps playing. That is the whole point of it, and it is why it needs six's help twice.

**Turning it on.** WebKit has the feature and hands the new API no switch for it. The preference is real —
`WKPreferencesSetAllowsPictureInPictureMediaPlayback` is exported by the framework on macOS — but the only public way
to set it is `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback`, which is declared for iOS alone, and
`WebPage.Configuration` has no field for it at all. Off is the default, and off is silent in exactly the way element
fullscreen was ([above](#filling-the-window)): no button in the media controls,
`video.webkitSupportsPresentationMode('picture-in-picture')` false, and `video.requestPictureInPicture()` rejecting
with `NotSupportedError — The video element does not support the Picture-in-Picture mode`. Measured on a plain
`<video>` through six's own MCP server, the day after the fullscreen fix landed: `{"pip": false, "fs": true}`.

So it is SPI: `WKPreferences._setAllowsPictureInPictureMediaPlayback:` to turn it on, `WKWebView._togglePictureInPicture`
for the menu item and the key, `_isPictureInPictureActive` for the question below. All of it lives in
`six/Browser/PagePictureInPicture.swift`, all of it behind `responds(to:)`, on the terms [todo.md](todo.md) already
set for SPI here: six is not sandboxed and not on the App Store, so the only risk is a selector going away in a macOS
update, and the shape that takes is a feature that is quietly not there rather than a crash. The fragile part is not
the selectors but the way to the `WKWebView` behind a `WebPage`, which the new API does not hand out — it is a `lazy`
stored property of the model object and `Mirror` is the way in. Reading any property of the page is what builds it.

**Keeping it alive.** A column far from the viewport loses its live `WebView` (`isLive`, above), and further out its
page (`LivePageCache`). Losing the view turns out not to matter: the floating player is a window of WebKit's, not a
subview, and it goes on playing while the column that owns it is unmounted — measured by scrolling to a window in
another profile entirely and asking the page what its presentation mode was. Losing the *page* would take the video
off the screen the user is looking at, so `keepAliveReason` asks `isInPictureInPicture` before anything else. The
"playing media" guard that was already there does not cover it: a floating player paused for a moment is still a
window somebody put on their screen on purpose.

Whether a window is in picture-in-picture is read off WebKit every time rather than remembered, because six is not
the only one who can put it there — the media controls' button, a site's own button and `⌥⇧P` all end in the same
place, and a flag six kept would be right only for the third. Nothing observes it, so nothing has to be told: the
menu asks when it is opened, the budget asks when it is about to evict, and both are moments where the answer is used
at once. For the same reason the menu item is never greyed out — whether the page in front of you has a video to
float is a question only the page can answer, and it changes with every play and pause without telling anyone.

**Where the window sits, and why six cannot move it.** The floating player is not six's window and not WebKit's
either: `WebPage` → `PIPViewController` → `PIPPanel` all live in six's process, but the thing on the screen is drawn by
`/System/Library/CoreServices/PIPAgent.app`, in a process of its own, on CoreGraphics layer 19 — above every ordinary
window, below the Dock. six's `PIPPanel` sits at level 0 and never appears in the on-screen window list at all; it is
where the events go, and the agent is where the pixels are. Three things follow, each of them measured rather than
reasoned:

* **It cannot be tied to six's window.** `addChildWindow` on the `PIPPanel` succeeds and the panel dutifully follows
  its parent around, and nothing on the screen moves — and worse, the player then survives leaving picture-in-picture,
  still visible six seconds later, because a child window is ordered back in by its parent after WebKit orders it out.
* **It cannot be placed.** The agent snaps the player to a corner of the **screen**, not of the window that owns the
  video, and remembers the choice for every application at once (`com.apple.PIPAgent`: `Corner`, and `Size` as a
  fraction of the screen). Measured with a host window 1100 points wide at (100, 120): the player landed in the corner
  of a 1440-point screen.
* **`PIPViewController._pipSetWindowContentRect:completion:` is the wrong direction.** It is how the agent tells six
  where the player went; calling it moves six's invisible `PIPPanel` and leaves the agent's window where it was.

This is what Safari gets, for the same reason — the whole path is WebKit's. Chrome and Firefox place and level their
mini-players because they draw them, and drawing one is not something a browser built on `WebPage` can do: there is no
way to take a `<video>` out of a page and into a window of one's own. So the two asks this produced — that the player
travel with the browser on ⌘Tab, and that it sit under the top bar rather than over it — are not bugs with a fix here.
The other feature of the same name is the answer if they matter enough: any six window as a floating always-on-top
panel, which is niri's floating layer, six's own `NSPanel` and therefore six's to parent and to place. It is not built;
it is in [todo.md](todo.md).

## Overview

`⌥O` zooms the whole canvas out and opens the vertical spacing so neighbouring workspaces read as separate screens.
The scale adapts: enough to show the focused rail end to end, never more than `overviewBaseScale` (0.5 — a short
rail shouldn't shrink for nothing) and never past `minimumOverviewScale` (0.22), where a long rail starts scrolling
instead of turning microscopic. Scrolling sideways pans the rail freely there; `visibleWidth` (the viewport divided by
the scale) is what every offset is measured against, so the same clamping code serves both modes. Leaving the overview
puts the rail back under the focused window.

Pages keep rendering but stop taking clicks — the same `ClickCatcher` covers every column — so one click focuses a
window and leaves the overview.

### Carrying a window

A window can be picked up in the overview and carried along its rail or onto another workspace. The gesture belongs to
the **canvas**, not to the card (`OverviewPointerLayer`): up there every window is a picture at a place the layout
already knows, so which one is under the pointer is arithmetic against `columnFrames()`, and a gesture that is not
attached to a card survives the card being carried out of the row that was drawing it. The layer sits in the rail's
own coordinate space (`NiriStripView.canvasSpace`, the canvas *before* the overview scales it, which is the space the
frames are already in), and offers the mouse only the cards themselves (`CardsShape`) — a click between two windows
still reaches what is under it, the New Window button on an empty workspace included.

Nothing on the rail moves until the drop. Until then `arrangement(workspaceAt:)` is what each row draws: the carried
window out of the row it came from and holding a place open in the row it would land in, with the card itself drawn
above every row at `carriedCardFrame` — where it was lifted from, plus how far the pointer has gone, so it stays under
the pointer exactly. Only the shuffle is animated; animating the card would mean it never quite catches up.

Where it would land is counted against the row **as it is**, not as it is being drawn: one window has gone past another
when their middles have crossed, which is a fixed line. Measuring against the shuffled row instead moves that line
towards the card every time it moves — the window to the right slides into the gap and its middle arrives under the
pointer at once, and the drop target flips back and forth for a pixel of travel. The focus goes with the window on the
drop: a window put in another row that left the view behind in the old one is a window you have just lost.
