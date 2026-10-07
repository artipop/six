# 23. A tab is a `WKWebView` of Savoia's own — what is left

Built on the `wkwebview` branch on 6–7 October 2026: every tab is a `WKWebView` that `BrowserTab` creates, nothing
imports `WebPage`'s API, and the workarounds it forced are out or have a line saying why they stayed. The map the
move was made by, and what became of each workaround, is
[architecture.md](../../architecture.md#from-webpage-to-wkwebview). This file holds what is not finished: a walk by
hand and the merge.

## What was checked, and how

- The build is free of warnings; `swift build` and `swift test` (254 tests) pass with `SavoiaCore` importing no
  WebKit — `SitePermissions` lost the two helpers that named WebKit types.
- `SAVOIA_KEY_SELFTEST` (`1`, `assistant`, `chats`, `alert`), `SAVOIA_TABS_SELFTEST`, `SAVOIA_FIND_SELFTEST`,
  `SAVOIA_WEBMCP_SELFTEST` and `SAVOIA_TRANSLATE_SELFTEST`, each in a throwaway home, before and after: the same
  lines, apart from the view's class name, and `alert` going from one failure to none. The translation one says
  little either way — in a fresh home it lands on the welcome page and finds no plan.
- Scenarios over `Savoia --mcp` in a throwaway home: navigation and reading, history and scroll across a discard and
  a relaunch for a tab off screen, the three kinds of `window.open` with a message back to the opener, a clicked
  `target=_blank`, element fullscreen entered by a real click and left by navigating, every Save As format, and an
  extension's page through a discard and a relaunch.
- `./scripts/permissions-wpt.py permissions --no-testdriver`: nothing moved against the baseline. The camera, the
  microphone and screen sharing were left out on purpose, and `webmcp-wpt.py` was not run.

## To walk by hand

No test covers these, and nothing here can click, hover or look at the screen:

- the context menu on a link, on a page and in a document's preview — it is built from SPI
  (`_webView:getContextMenuFromProposedMenu:forElement:…`), seen only on a throwaway view with a synthetic right
  click; its Share items; an extension's own items in it;
- a certificate error and the page for it; a download, and one that a new tab was opened only to carry;
- a ⌘-click, a `target=_blank`, back and forward by swipe;
- a video in fullscreen — whether the picture is drawn, which is what the old hold was for — and picture-in-picture;
- the camera in a call, and screen sharing with its mute;
- a sign-in through a window the site opens (Sign in with Google, Telegram's widget), now a tab that keeps its
  opener and no longer a window of the asked size;
- an extension's popup, its options page and the new-tab override;
- find, translation, ⌘E on a selection, a discarded tab coming back, a restored tab not starting its video;
- Save As to a web archive through the panel, and the archive opened again;
- remote automation: the switch in Develop, the orange mark on a tab opened with `automation_open_window`, and
  the switch turned off while such a tab is open;
- memory with ten tabs, against `main` — the dev Mac has 8 GB.

## Decisions

- **The automation flag is not set on ordinary tabs** — a page reads it as `navigator.webdriver`. It is set on
  tabs opened for remote automation, a mode of its own that is off by default
  ([devtools.md](../../devtools.md#remote-automation)), as Artem decided on 7 October 2026.
- **A window a page opens by itself is not blocked, and will not be** — decided by Artem on 7 October 2026. It
  was not blocked before the move either ([links.md](../../links.md#a-second-window)).

## The other fronts

`SavoiaCore` knows no engine, as before, and the protocols a front implements kept their shape. Two things for the
next sync of `dev`: `TabSnapshot.back` / `forward` are still in the format and no longer written or read by the Mac,
and the iOS front there is still on `WebPage` — `PageDelegate` and `BrowserTab.materialize` are where the same move
starts, with `PageHost`, `PageContextMenu` and the dialogs being the AppKit parts.

## Done when

The list above is walked and `wkwebview` is merged into
`main`. This file goes with that commit.
