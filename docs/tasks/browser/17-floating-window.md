# 17. A tab as a small window that floats

Two different features deserve the name, and the first of them is now built.

**Video PiP** — WebKit's own, for `<video>` — is done: `⌥⇧P`, a View menu item, and the button in WebKit's own media
controls. `WebPage.Configuration` turned out to have no field to allow it in, so it is SPI on the terms above, and the
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

A floating window cannot hold a `WebPage` tab's view while the tab bar also shows it. Windows a page opens are
already a `WKWebView` in an `NSWindow` (`Savoia/Browser/ScriptedPopups.swift`), and a page that lost its view by
navigating out of fullscreen taught what moving a `WebPage`'s view costs
([permissions.md](../../permissions.md#compatibility-web-platform-tests)). Measure first whether the page's own view
can be re-parented into a panel and back without the tab going blank.

## Done when

A tab can be floated and returned from the keyboard and the menu, keeps playing and keeps its page across both
moves, and [layout.md](../../layout.md) says how.
