# 3. Popups: tab or window, and what the window lacks

Finish the windows opened with `window.open`.

## Where it stands

`Savoia/Browser/ScriptedPopups.swift`, [links.md](../../links.md#a-second-window),
[todo.md](../../todo.md). Every `window.open` is an `NSWindow` holding the `WKWebView` WebKit asked for, so it has
its opener. A `target=_blank` link is still a tab. `SAVOIA_NO_POPUPS=1` goes back to a tab with no opener.

## Two gaps

1. **Sites that call `window.open(url)` to mean "a new tab" get a separate window too.** Safari gives those a tab
   that still has its opener, which a `WebPage` tab cannot be. One rule would be `WKWindowFeatures`: a size asked
   for → a window, none → a tab as before, without an opener. Before choosing, show Artem what five or six real
   sites actually ask for, and propose the rule; do not pick it alone.
2. **The window has none of a tab's features.** `alert` shows nothing and `confirm` is false; the camera and the
   microphone get WebKit's own prompt, which remembers nothing; no downloads. It needs at least the page's dialogs
   and an answer to camera and microphone through `SitePermissions`.

## Done when

- An OAuth sign-in through a popup goes all the way through on a real service — Artem checks by hand: prepare the
  build and say what to press.
- No regressions in wpt: `./scripts/permissions-wpt.py permissions-policy storage-access-api`.
- The guide ([guide/windows.md](../../guide/windows.md), both languages) says what a person now sees.
