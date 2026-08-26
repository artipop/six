# The niri layout

Modelled on [niri](https://github.com/YaLTeR/niri). There are no tabs and no sidebar.

- A page is a **column**: a full-height window with its own title bar (back/forward/reload, address field, close).
- Columns sit left to right in an endlessly scrollable **strip**. One strip is a **workspace**.
- Workspaces are stacked **vertically**; exactly one is on screen. Each profile has its own stack.
- A workspace can be **named** (double-click its plate in the overview). Naming is optional; an unnamed one is just
  "Workspace N". A named workspace survives running out of windows, an unnamed one disappears — same as niri.

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
and on a 5K panel. Widths are fractions of the working area (`widthPresets = [0.5, 2/3, 0.88, 1.0]`, default `0.88`),
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
cards (`ColumnPlaceholder`), so a long strip stays cheap. Restricting that to the *current* workspace is not only about
cost: a web view is a real AppKit view, SwiftUI's clipping does not reach it, and one parked a screen above still
answers the mouse over the top bar — which is how clicking a button up there could fly you to the workspace above. Off
screen, it must not exist. The neighbours come back while a gesture is peeking at them (`verticalPreview != 0`) and in
the overview, where every workspace is on screen; a column of another workspace never captures clicks outside it.

## Gestures — `six/Niri/NiriScrollMonitor.swift`

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
| `⌥F` | **compact width** | the widest preset (`1.0`), still tiled: the outer gaps and the title bar stay |
| `⌥W` | **full window** | the page fills the window under the top bar — no gaps, no title bar |
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

Leaving: the same key again, the Layout menu, the right-click menu, the `⤢` button in the top bar (full window), or —
for fullscreen — `⎋` and the bar's own button. `⎋` comes through the scroll monitor's key monitor rather than SwiftUI,
because a page holds the first responder and a key press would never reach the view hierarchy; WebKit's own full-screen
window (a video playing) is left alone, so `⎋` there still belongs to the video. `⎋` deliberately does not leave full
window: that mode is ordinary browsing, where a page's own `⎋` is worth more. `⌘L` leaves whichever mode is on, since
the address bar is part of what they hide. Closing the last window of the workspace leaves too — a blank wall with no
chrome is a trap.

**Controls over a page have to be AppKit.** SwiftUI drawn over a `WKWebView` never sees the mouse (the reason
`ClickCatcher` exists), and with the window filled there is nothing *but* page under them. So the edge chevrons and the
fullscreen bar are hosted in `NSHostingView` (`HostedOverlay`) — which must be frame-driven (`sizingOptions = []`,
`translatesAutoresizingMaskIntoConstraints = true`), or it publishes its size into the window's constraints and the
update passes never settle. In fullscreen the chevrons give way to the bar at the top edge, which carries the same two
steps plus the workspaces, the overview and the way out; the ⌘K line tucks itself away there until it is asked for or
has an answer to show. The window buttons stay where macOS puts them, so the bar leaves room for them.

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
window and leaves the overview. A click on a title bar does the same.
