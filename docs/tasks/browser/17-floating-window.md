# 17. A tab as a small window that floats

Two different features deserve the name, and the first of them is now built.

**Video PiP** — WebKit's own, for `<video>` — is done: `⌥⇧P`, a View menu item, and the button in WebKit's own media
controls. Allowing it on macOS is SPI on the terms above, and the
floating player survives its window being scrolled out of the row, turned into a placeholder card and left behind for
another profile. What it took, and what was measured, is in [layout.md](../../layout.md#picture-in-picture).

**Window PiP** is not. Any Savoia window as a small always-on-top panel: an `NSPanel` at `.floating` level hosting the
page, which leaves the strip while it floats and returns to its column when closed. This is a floating layer, and
the same mechanism would later serve a proper floating-window mode. Nothing about the video half helps here — that one
is not even a window WebKit owns: `PIPAgent` draws it in a process of its own, on a system layer, snapped to a corner
of the screen, and Savoia can neither parent it to the browser window nor place it
([layout.md](../../layout.md#picture-in-picture) has the measurements). Which is the argument for this half: a floating
window Savoia draws is one it can put under the top bar and carry with the browser, and those are the two things asked
for about the video player that could not be answered.

## Before building

A tab's `WKWebView` is Savoia's own and sits in a plain host view (`PageHost`), which takes it from whichever host
had it before — so moving it into a panel and back is `addSubview` twice. WebKit already does exactly that for
element fullscreen, and the view comes back ([architecture.md](../../architecture.md#from-webpage-to-wkwebview)).
Measure first that a page keeps playing and keeps its size across the move, and what the tab bar shows meanwhile.

## Done when

A tab can be floated and returned from the keyboard and the menu, keeps playing and keeps its page across both
moves, and [layout.md](../../layout.md) says how.
