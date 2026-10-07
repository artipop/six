# Unmeasured

Claims this repository makes, or nearly makes, that nobody has watched happen. Each one is a thing that would take
one sitting to settle; they live here rather than in the page they belong to, because a page that says "believed"
in six places is a page nobody trusts and nobody fixes.

A line leaves this file by being measured, in either direction, and by the page it came from being rewritten to say
what was seen. Say when it was measured and on what.

## uBlock Origin Lite scored 96/100, and the control run is missing

**2026-09-22, macOS, dev build.** uBOL at its strictest setting scored **96 of 100** on
`https://adblock-tester.com`, with Savoia's own **Block Ads and Trackers** switch off in that profile. Script-loading
rows came back yellow on some runs and green on others.

[extensions.md](extensions.md) says uBOL **blocks nothing here** — measured before `WKWebExtensionTab.webView(for:)`
started answering. Those two cannot both be true, and the guide repeats the old one in
[ru](guide/extensions.md) and [en](guide/en/extensions.md).

What is missing before the old claim is struck out:

- **The control run.** Same profile, uBOL switched off, page reloaded. If the score barely moves, the blocking was
  never uBOL's.
- **Whether that switch is a switch.** The Blocking toggle was *off* in the UI; that Savoia then applies no rule list of
  its own is exactly the kind of thing this file exists for. Same page with uBOL off and blocking off is the
  measurement: a high score with both off means something else is blocking and neither result means anything yet.
- **What kind of blocking it is.** `adblock-tester.com` counts requests, and `declarativeNetRequest` — which WebKit
  implements and Savoia has watched blocking — is enough to score well. The part that was never in doubt is not the
  part that is in doubt.

## uBOL's per-tab half

Its badge count, its per-site disable, and its cosmetic filtering all decide by tab, which is what the
`webView(for:)` gap took away. The score above says nothing about any of them, and the yellow script-loading rows
are where they would show.

- Does the badge number change as the row moves between sites?
- Does "disable on this site" in uBOL's own popup survive a reload?
- Do elements *disappear* rather than merely fail to load —
  `https://testpages.adblockplus.org/en/filters/element-hiding` and its neighbours.

## The four calls behind the verdict

[extensions.md](extensions.md) records these as broken, measured before the fix, and says outright that the re-test
hit a wall one step short of proving anything. `ExtensionInstaller.permissionSupport` therefore calls `scripting`
**unchecked** on the Mac rather than working, and the install dialog says so about every extension that asks for it.

- `runtime.sendMessage` from a content script
- `tabs.sendMessage` to a content script
- `scripting.executeScript`
- `scripting.insertCSS`

The instrument is a three-file MV3 extension of our own, loaded with `SAVOIA_EXTENSION=/path/to/unpacked`: a content
script that messages its background and writes the reply into `document.title`, a background that answers and then
calls `insertCSS` and `executeScript` at the same tab, and one read through `Savoia --mcp`:

```js
return [document.title, window.__probe, getComputedStyle(document.body).backgroundColor]
```

Three values, four calls, one page. Errors land in `list_console_messages` and in the app's own log as
`[extensions] <name> reports …`. It has to be an ordinary page in an ordinary window: extensions do not run in
private browsing, and `savoia://` pages have no content scripts.

## An agent's hover and drag, past the stand page

**2026-10-07, macOS, dev build.** `hover` and `drag` over `Savoia --mcp` passed seven steps on a page written for
them, with Savoia in the background and launched in front ([agent-actions.md](agent-actions.md#hover-and-drag-the-pointer)).
What that leaves:

- **A window known to be key.** `document.hasFocus()` answered false in every run, the ones in front too, so
  nobody knows the page was in the key window. The first fault found — a dragging session following the person's
  pointer — showed only with Savoia in front, so this is the case most likely to hide another.
- **What a person sees.** Artem watched one run and it went by too fast to judge. Slow it down, or draw the window
  with `testdriver_window_image` after `hover` and after a refused `drag`: is the menu open, is anything left on
  screen.
- **A page inside a frame.** The acting tools are main frame only; nobody has run `hover` or `drag` at an element
  in an `iframe` to see what the refusal says.
- **A real site.** A Trello-like board, a SortableJS list, a page that checks `event.buttons` on `mousemove` — the
  last is expected to let go, since the page reads the buttons from the system.
- **Hover in wpt.** The runner's `pointerMove` reached no page until this day. 109 files with testdriver under
  `pointerevents`, `uievents` and `css/selectors` name `mouseover`, `mouseenter`, `:hover` or their pointer
  twins, and none has been run since; the permission baseline was not rerun either.
- **Drag-and-drop in wpt measures nothing yet.** A run of `html/editing/dnd` stopped at 50 files: 18 passed, 31
  timed out, every one the same as Safari's row. The runner sends down, move, up past `PageActions.drag`, so
  those are the raw path's timeouts and not the tool's. Before they mean anything the press has to be kept at the
  web view — down declines the session, a move after `dragstart` is the destination's `draggingUpdated`, up is the
  drop — with the tool and the runner both on it. **Do not run them on the raw path while Artem is at the Mac**:
  each starts a real dragging session and writes the system's drag pasteboard, and it got in the way of his work.
- **Whether WebKit's automation starts a dragging session too**, when `performInteractionSequence` presses and
  moves over a `draggable` element. Reasoned, not measured.
- **Chrome's and Firefox's rows for the same files** on wpt.fyi were not read, so it is not known how many of the
  31 a browser passes at all.

The instrument is a page with a CSS hover menu, a `mouseenter` tooltip, a list sorted on `mousemove`, a list of
`draggable` items, a drop target and an element that takes no drops, each with a button or a `draggable` element
inside so the snapshot gives it a ref, and a `state()` that returns the lists' order, the menu's `display`, the
tooltip's text and the event log. Seven tool calls — `hover` twice, `drag` four times, the last onto the refusing
element, then `click` — and `state()` read through `evaluate_javascript` after each.

## What the move to `WKWebView` left to eyes and hands

**2026-10-06 to 08, macOS, dev build, throwaway homes.** Every tab became a `WKWebView` of Savoia's own
([architecture.md](architecture.md#from-webpage-to-wkwebview)). The self-tests, the wpt runs and a set of scenarios
over `Savoia --mcp` came out the same as before the move or better, and these were watched happen: a download and
the tab opened only to carry it, a certificate failure and its page (read in a drawing of the window), a restored
tab that does not start its sound and plays on the next navigation, an extension's options page and its new-tab
override as tabs, `window.open` with a message back to the opener, element fullscreen entered by a real click and
left by navigating. What nobody has watched:

- **The context menu.** It is an `NSMenu` built from SPI (`PageContextMenu`, `PageDelegate`), and the SPI was
  exercised once, on a throwaway `WKWebView`, with a synthetic right click. In Savoia nobody has opened it: on a
  link, on a page, in a document's preview; its Share items; an extension's own items in it. Half of this needs
  no eyes — a test-driver tool that asks for the menu at a point and lists its items.
- **A ⌘-click.** The delegate cancels it and opens the link behind; no run has sent one. `testdriver_click` holds
  no modifiers, and a click sent through `Automation.performInteractionSequence` reached no page in the one
  attempt, plain or modified — most likely the command was put together wrongly.
- **A web archive opened again.** Save As answers `bplist00` bytes of a plausible size; the file was never written
  through the panel or loaded back into a tab.
- **Back and forward by swipe.** `allowsBackForwardNavigationGestures` is set; no gesture can be sent from here.
- **The picture in fullscreen, and picture-in-picture.** The state, the size and the way home are measured; whether
  anything is drawn is not, and a black screen was the fault the removed workaround was for.
- **A call.** The camera's question passes in wpt on a stand page; a real call, screen sharing with its picker and
  the mute buttons in the address field were not tried.
- **A sign-in through a window the site opens** — Sign in with Google, Telegram's widget. It is a tab now, and
  the size it asks for is not honoured; only the mechanics were measured, on a stand page.
- **An extension's popup.** WebKit's own popover, pointed at the toolbar button.
- **Translation.** `SAVOIA_TRANSLATE_SELFTEST` in a fresh home lands on the welcome page and finds no plan, so it
  said nothing before the move or after.
- **The lock in the address field on a failed https load.** The drawing of the certificate page shows it. Whether
  it was there before the move was not checked.
- **The key ring's self-test on the last build.** `SAVOIA_KEY_SELFTEST=1` read "no key window" in its last two
  runs, with the screen locked or another app in front; `=alert` was run by Artem on a free Mac and passed.
