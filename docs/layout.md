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

Widths are fractions of the working area (`widthPresets = [0.5, 2/3, 0.88, 1.0]`, default `0.88`): an ordinary browser
window with the next one peeking in at the edge. One gap is folded into `usableWidth`, so N columns of `1/N` fill the
screen exactly. A strip narrower than the viewport is centred instead of pinned left.

Focus moves the view as little as possible — `scrollFocusIntoView` only scrolls until the focused column is fully
visible, which is what makes the peeking neighbour stay peeking.

Only columns within one workspace and one viewport-width of the screen get a real `WebView`; the rest render as cards
(`ColumnPlaceholder`), so a long strip stays cheap.

## Gestures — `six/Niri/NiriScrollMonitor.swift`

A local `NSEvent` monitor sees scroll events before WebKit does. It acts on them when `⌥` is held, when the overview is
open, or — unmodified — when the pointer is over the layout's own chrome. "Chrome" is decided by hit-testing the event
point: anything inside a `WKWebView`, `NSScrollView` or `NSTextView` keeps its own scrolling, everything else (title
bars, gaps, background, top bar) drives the layout.

Vertical is **one workspace per gesture**: deltas accumulate into a rubber-band preview (`verticalPreview`), crossing
the threshold commits the switch, and the rest of the gesture — trackpad momentum included — is swallowed, so a flick
never skips two. Discrete mouse wheels have no gesture phase and are throttled by time instead. Horizontal is free
panning; on release focus snaps to the column nearest the middle of the screen.

Tuning lives at the top of the file: `threshold` (55 pt), `minimumCommitInterval` (0.28 s), `idleReset` (0.25 s).

## Overview

`⌥O` scales the whole canvas to 0.5 and opens the vertical spacing so neighbouring workspaces read as separate
screens. Pages keep rendering but stop taking clicks: one click focuses a window and leaves the overview.
