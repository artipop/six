# The niri layout

Modelled on [niri](https://github.com/YaLTeR/niri). There are no tabs and no sidebar.

- A page is a **column**: a full-height window with its own title bar (back/forward/reload, address field, close).
- Columns sit left to right in an endlessly scrollable **strip**. One strip is a **workspace**.
- Workspaces are stacked **vertically**; exactly one is on screen. Each profile has its own stack.

## Model — `six/Niri/NiriLayout.swift`

```
NiriStrip     workspaces: [NiriWorkspace], focus: Int      // one per profile
NiriWorkspace columns: [NiriColumn], focus: Int, viewOffset: CGFloat
NiriColumn    tabID: UUID, widthIndex: Int                 // points at a BrowserTab
```

Every mutation goes through `mutate { }`, which runs `normalize` afterwards, so the invariants hold by construction:

- **Dynamic workspaces.** Exactly one empty workspace is kept at the bottom; empty ones in between are dropped. The
  trailing workspace keeps its identity across the prune, so focus survives it.
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

Only columns within one workspace and one viewport-width of the screen get a real `WebView`; the rest render as cards
(`ColumnPlaceholder`), so a long strip stays cheap.

## Gestures — `six/Niri/NiriScrollMonitor.swift`

A local `NSEvent` monitor sees scroll events before WebKit does. It acts on them when `⌥` is held, when the overview is
open, or — unmodified — when the pointer is over the layout's own chrome. "Chrome" is decided by hit-testing the event
point: anything inside a `WKWebView`, `NSScrollView` or `NSTextView` keeps its own scrolling, everything else (title
bars, gaps, background, top bar) drives the layout.

Vertical is **one workspace per gesture**: deltas accumulate into a rubber-band preview (`verticalPreview`), crossing
the threshold commits the switch, and the rest of the gesture — trackpad momentum included — is swallowed, so a flick
never skips two. Discrete mouse wheels have no gesture phase and are throttled by time instead.

Horizontal works the same way **while centring is on**: one window per gesture, with a `horizontalPreview` rubber band
below the threshold. The strip then has no free resting position — `panStrip` refuses to move it at all, so no gesture
can leave a window sitting half-way. With centring off (`⌥C`) horizontal scrolling pans the strip freely, and on
release focus snaps to the column nearest the middle and scrolls it fully into view.

Tuning lives at the top of the file: `threshold` (55 pt), `minimumCommitInterval` (0.28 s), `idleReset` (0.25 s).

## Overview

`⌥O` scales the whole canvas to 0.5 and opens the vertical spacing so neighbouring workspaces read as separate
screens. Pages keep rendering but stop taking clicks: one click focuses a window and leaves the overview.
