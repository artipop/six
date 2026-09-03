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
- One profile's windows only. A profile is a browsing world with a rail, a history and a colour of its
  own, and a key that flew you out of one into another would change all of that on the way past.
- Nothing is loaded while it is walked: the cards are the pictures the overview already takes
  (`rememberViewState` for the window being read, `loadPictureIfNeeded` for the rest). The flight
  happens once, on `⌃` coming up, through `selectTab` and the usual switch animation.

The keys come through `NiriScrollMonitor` for the reason the `⌥` bindings do — a first-responder
`WKWebView` answers a key equivalent before the menu bar sees it — and for a second reason besides:
the ring is held open by a modifier, and only a `flagsChanged` ever says a modifier was let go of. A
key that is not `Tab` arriving mid-ring ends the pass and is passed on, so nothing can leave the
switcher standing (the app losing focus mid-press, most of all). The panel is `WindowSwitcherOverlay`,
mounted on `ContentView` over the top bar as well as the rail, and it answers no mouse: it exists only
while a key is held, and a target that vanishes when you let go of a key is not a target.

## Clicking

A window that isn't focused is a target, not a page: the first click flies to it (and centres it) instead of reaching
the page. The catcher has to be an AppKit view — `WKWebView` is a real `NSView` and takes the click before any SwiftUI
overlay above it can — so `ClickCatcher` is an `NSViewRepresentable` laid over the web view of every unfocused column.
Title bars are SwiftUI and keep their own buttons working, so a background window's close or back button still takes
one click.

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
button) still does the thing people actually want from the word, and a page's own `requestFullscreen` is WebKit's and
untouched.

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
