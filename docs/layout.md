# The niri layout

Modelled on [niri](https://github.com/YaLTeR/niri). There are no tabs and no sidebar.

- A page is a **column**: a full-height window that is nothing but the page, edge to edge inside a rounded card.
  Everything that used to be drawn on it — the lock, the shield, the address, the title — is in the top bar, for the
  focused window only, because a strip of a dozen windows does not want a dozen address fields. The `×` is the one
  thing that stayed with the window: it sits on the card's top right corner, invisible until the pointer is on it.
- Columns sit left to right in an endlessly scrollable **strip**. One strip is a **workspace**.
- Workspaces are stacked **vertically**; exactly one is on screen. Each profile has its own stack.
- A workspace can be **named** (double-click its plate in the overview). Naming is optional; an unnamed one is just
  "Workspace N". A named workspace survives running out of windows, an unnamed one disappears — same as niri.

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
NiriColumn    tabID: UUID, widthIndex: Int                 // points at a BrowserTab
```

Every mutation goes through `mutate { }`, which runs `normalize` afterwards, so the invariants hold by construction:

- **Dynamic workspaces.** Exactly one empty workspace is kept at the bottom; empty ones in between are dropped, unless
  they are named. The trailing workspace keeps its identity across the prune, so focus survives it.
- Column focus stays in range, and `viewOffset` stays clamped.

## Geometry

**Everything here is a fraction of the viewport, never a pixel count** — the layout has to read the same on a laptop
and on a 5K panel. Widths are fractions of the working area (`widthPresets = [0.5, 2/3, 0.88, 1.0]`, default `0.88`). The
preset is one value for the whole app (`preferredWidthIndex`, kept in settings): `⌥R` / `⌥⇧R` step it wider / narrower for every window in every
strip, and new windows open with it — unlike niri, where each column has its own; a strip of mixed widths reads as a mess.
gaps are `gapFraction` (1 % of the width), the vertical space between workspaces is `workspaceGapFraction` (2 % of the
height). The absolute numbers left in the file are floors (`minimumGap`, the 280 pt minimum column) that only matter
in a tiny window. Control metrics — title bar heights, button sizes, corner radii — deliberately stay in points, since
text and controls don't scale with the screen either.

So the default column keeps ~7 % of the screen visible of each neighbour at any size: 89 pt at 1280 wide, 178 pt at
2560, 238 pt at 3440. One gap is folded into `usableWidth`, so N columns of `1/N` fill the screen exactly, and a strip
narrower than the viewport is centred instead of pinned left.

The focused column is **centred** by default (niri's `center-focused-column`), so both neighbours peek in by the same
amount; while centring is on the strip may scroll until the first/last column reaches the middle, which is what lets
every column get there. `⌥C` turns it off, and focus then moves the view as little as possible — `scrollFocusIntoView`
scrolls only until the focused column is fully visible. The choice persists in `UserDefaults`.

Offsets are stored per workspace but the geometry that produced them is global, so a strip that was laid out at another
viewport — the other profile's, or one restored from `state.json` — would come back scrolled off centre. `recenterStrips`
puts every strip back under its focused window whenever the viewport or `⌥C` changes, and switching `activeProfileID`
does the same for the strip coming on screen.

Only columns of the workspace on screen, within one viewport-width of it, get a real `WebView`; the rest render as
cards (`ColumnPlaceholder`), so a long strip stays cheap. Whether a column *has* a page to mount at all is a separate
question and the live-page budget's — see [architecture.md](architecture.md#live-pages): the strip pins what is on
screen and builds only the focused window, once the focus has settled, so walking the strip loads the window you stop
at rather than every window you pass. In the overview nothing is mounted and nothing is built; every window there is a
card, and a card is its title in the strip and the last picture of the page in the overview.

Restricting live views to the *current* workspace is not only about cost: a web view is a real AppKit view, SwiftUI's
clipping does not reach it, and one parked a screen above still answers the mouse over the top bar — which is how
clicking a button up there could fly you to the workspace above. Off screen, it must not exist. The neighbours come
back while a gesture is peeking at them (`verticalPreview != 0`).

The same is true of everything else a workspace off screen contains, which is the other half of that bug: cards and
their shadows reach into the top bar's band too — how far depends on the window's size, since the gaps are fractions of
the viewport — and that is enough to take a click off a button there, intermittently. So a workspace that is not the
current one answers nothing at all (`allowsHitTesting`), unless the overview is open and it really is on screen; and
the top bar is `zIndex`-ed in front of the strip, since they are siblings in a stack and the strip is hit-tested after
it.

## Gestures — `six/Niri/NiriScrollMonitor.swift`

*This section is AppKit's. The GTK front reaches the same gestures through a
`GtkEventControllerScroll` in the capture phase, where the boundaries of a gesture are explicit
rather than inferred — which is one of the few places the second front had an easier time.*


A local `NSEvent` monitor sees scroll events before WebKit does. It acts on them when `⌥` is held, when the overview is
open, or — unmodified — when the pointer is over the layout's own chrome. "Chrome" is decided by hit-testing the event
point: anything inside a `WKWebView`, `NSScrollView` or `NSTextView` keeps its own scrolling, everything else (title
bars, gaps, background) drives the layout.

Without `⌥` the pointer must also be **inside the strip** (`stripFrame`, published by the view in SwiftUI's window
coordinates and flipped in the monitor, which measures from the bottom of the window). The top bar is chrome too, and
letting it drive the layout made clicking one of its buttons a gamble: a hair of finger travel on a trackpad switched
the workspace under the cursor. Held `⌥` still works anywhere — then it is an explicit layout gesture.

Vertical is **one workspace per gesture**: deltas accumulate into a rubber-band preview (`verticalPreview`), crossing
the threshold commits the switch, and the rest of the gesture — trackpad momentum included — is swallowed, so a flick
never skips two. Discrete mouse wheels have no gesture phase and are throttled by time instead.

Horizontal works the same way **while centring is on**: one window per gesture, with a `horizontalPreview` rubber band
below the threshold. The strip then has no free resting position — `panStrip` refuses to move it at all, so no gesture
can leave a window sitting half-way. With centring off (`⌥C`) horizontal scrolling pans the strip freely, and on
release focus snaps to the column nearest the middle and scrolls it fully into view.

Tuning lives at the top of the file: `threshold` (55 pt), `minimumCommitInterval` (0.28 s), `idleReset` (0.25 s).

## Clicking

A window that isn't focused is a target, not a page: the first click flies to it (and centres it) instead of reaching
the page. The catcher has to be an AppKit view — `WKWebView` is a real `NSView` and takes the click before any SwiftUI
overlay above it can — so `ClickCatcher` is an `NSViewRepresentable` laid over the web view of every unfocused column.
Title bars are SwiftUI and keep their own buttons working, so a background window's close or back button still takes
one click.

## Filling the window, and the screen

Three steps, each one taking away more of what is not the page:

| | | |
|---|---|---|
| `⌥F` | **compact width** | the widest preset (`1.0`), still tiled: the outer gaps and the card stay |
| `⌥W` | **full window** | the page fills the window under the top bar — no gaps, no card, no corners. Also the layout button in the top bar: a click there fills and unfills |
| `⌥⇧F` | **fullscreen** | the top bar goes too; only a bar hiding at the top edge comes back |

The last two are `NiriFill.window` and `.screen` on the layout — a mode, not per-window state. `fillsViewport` is what
the geometry asks (both of them), `showsFullscreen` what the top bar asks (only `.screen`), and both are false while
the overview is open, so it keeps its gaps and title bars and the mode returns when it closes. The strip goes on
working underneath either one: `⌥←` `⌥→` walk from window to window and the next one arrives filled too, so a
workspace reads like a stack of pages.

The geometry is the ordinary one with two overrides: `gap` (and with it `outerGap`) is 0, and `width(of:)` returns the
viewport width whatever the column's preset says — the presets are untouched, so leaving restores them. Every column
being exactly one screen wide is what makes the alignment fall out for free: centred or not, the resolved offset of the
focused column lands on a whole multiple of the viewport. Changing the mode changes every width, so `setFill`
re-centres every strip, as `⌥C` and a resize do.

Switching is deliberately **not** animated, unlike everything else the layout does. Every switch resizes every live
page, and a web view changing size costs a hitch you can see — around 50 ms with three columns live. Running that
through the 0.34 s spring spreads the stutter over the whole animation instead of getting it over with: measured over
six switches, 20 dropped frames animated against 5 instant. (The neighbours stay live on purpose, so stepping to the
next full window shows a page rather than a card; that is what makes the third resize worth paying for.)

Leaving: the same key again, the Layout menu, the right-click menu, the layout button in the top bar (a click there
is full window on and off; the same menu holds all three modes), or — for fullscreen — `⎋` and the bar's own button. `⎋` comes through the scroll monitor's key monitor rather than SwiftUI,
because a page holds the first responder and a key press would never reach the view hierarchy; WebKit's own full-screen
window (a video playing) is left alone, so `⎋` there still belongs to the video. `⎋` deliberately does not leave full
window: that mode is ordinary browsing, where a page's own `⎋` is worth more. `⌘L` leaves whichever mode is on, since
the address bar is part of what they hide. Closing the last window of the workspace leaves too — a blank wall with no
chrome is a trap.

**Controls over a page have to be AppKit.** SwiftUI drawn over a `WKWebView` never sees the mouse (the reason
`ClickCatcher` exists), and with the window filled there is nothing *but* page under them. So the step chevrons and the
fullscreen bar are hosted in `NSHostingView` (`HostedOverlay`) — which must be frame-driven (`sizingOptions = []`,
`translatesAutoresizingMaskIntoConstraints = true`), or it publishes its size into the window's constraints and the
update passes never settle.

The chevrons stand in the **gap beside the focused window** (`focusedColumnFrame`), not against the edge of the screen
where the neighbour peeking in is, and they are as narrow as that gap — a button wide enough to read comfortably is a
button covering the page next to it. Tiled they rest at a third of their opacity; filled, the gap is gone and the
sliver is over the page, so it drops to nothing and comes back under the pointer. Invisible is not absent: a SwiftUI
button at zero opacity still answers the mouse, which is what makes the sliver its own hover target. In fullscreen the chevrons give way to the bar at the top edge, which carries the same two
steps plus the workspaces, the overview and the way out; the ⌘K line tucks itself away there until it is asked for or
has an answer to show. The window buttons stay where macOS puts them, so the bar leaves room for them.

At either end of the strip the chevron gives way to a button that opens a window, and the one at the near end opens it
*before* the focused one (`NiriPlacement`) — the strip has no other way of growing backwards. That button draws
**nothing**: resting on it leans the whole strip aside (`newColumnHover`, `newColumnLean`) and stands a dashed outline
of the window in the room it makes (`newColumnFrame`). That outline is the whole of the offer — a `+` on the edge, or
in the room, would be the same thing said twice.

Two decisions hold it together. The lean goes exactly as far as the glance a window opening behind gets
(`peekAmount`, a fraction of the viewport) — one distance for both, because they are the same sentence, *there is
something over here*. It is deliberately *not* `horizontalPreview`: that band belongs to the scroll gesture, and a peek
held by the mouse has to survive one arriving. And `focusedColumnFrame` deliberately does not include it, so the button
does not slide out from under the pointer holding it.

Three things share the word "fullscreen" and are not the same: this (a layout state), macOS fullscreen (the green
button — the strip just fills a bigger window), and a page's own `requestFullscreen`, which WebKit handles inside the
web view.

## Overview

`⌥O` zooms the whole canvas out and opens the vertical spacing so neighbouring workspaces read as separate screens.
The scale adapts: enough to show the focused strip end to end, never more than `overviewBaseScale` (0.5 — a short
strip shouldn't shrink for nothing) and never past `minimumOverviewScale` (0.22), where a long strip starts scrolling
instead of turning microscopic. Scrolling sideways pans the strip freely there; `visibleWidth` (the viewport divided by
the scale) is what every offset is measured against, so the same clamping code serves both modes. Leaving the overview
puts the strip back under the focused window.

Pages keep rendering but stop taking clicks — the same `ClickCatcher` covers every column — so one click focuses a
window and leaves the overview.

### Carrying a window

A window can be picked up in the overview and carried along its strip or onto another workspace. The gesture belongs to
the **canvas**, not to the card (`OverviewPointerLayer`): up there every window is a picture at a place the layout
already knows, so which one is under the pointer is arithmetic against `columnFrames()`, and a gesture that is not
attached to a card survives the card being carried out of the row that was drawing it. The layer sits in the strip's
own coordinate space (`NiriStripView.canvasSpace`, the canvas *before* the overview scales it, which is the space the
frames are already in), and offers the mouse only the cards themselves (`CardsShape`) — a click between two windows
still reaches what is under it, the New Window button on an empty workspace included.

Nothing in the strip moves until the drop. Until then `arrangement(workspaceAt:)` is what each row draws: the carried
window out of the row it came from and holding a place open in the row it would land in, with the card itself drawn
above every row at `carriedCardFrame` — where it was lifted from, plus how far the pointer has gone, so it stays under
the pointer exactly. Only the shuffle is animated; animating the card would mean it never quite catches up.

Where it would land is counted against the row **as it is**, not as it is being drawn: one window has gone past another
when their middles have crossed, which is a fixed line. Measuring against the shuffled row instead moves that line
towards the card every time it moves — the window to the right slides into the gap and its middle arrives under the
pointer at once, and the drop target flips back and forth for a pixel of travel. The focus goes with the window on the
drop: a window put in another row that left the view behind in the old one is a window you have just lost.
