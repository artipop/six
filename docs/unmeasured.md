# Unmeasured

Claims this repository makes, or nearly makes, that nobody has watched happen. Each one is a thing that would take
one sitting to settle; they live here rather than in the page they belong to, because a page that says "believed"
in six places is a page nobody trusts and nobody fixes.

A line leaves this file by being measured, in either direction, and by the page it came from being rewritten to say
what was seen. Say when it was measured and on what.

## uBlock Origin Lite scored 96/100, and the control run is missing

**2026-09-22, macOS, dev build.** uBOL at its strictest setting scored **96 of 100** on
`https://adblock-tester.com`, with six's own **Block Ads and Trackers** switch off in that profile. Script-loading
rows came back yellow on some runs and green on others.

[extensions.md](extensions.md) says uBOL **blocks nothing here** — measured before `WKWebExtensionTab.webView(for:)`
started answering. Those two cannot both be true, and the guide repeats the old one in
[ru](guide/extensions.md) and [en](guide/en/extensions.md).

What is missing before the old claim is struck out:

- **The control run.** Same profile, uBOL switched off, page reloaded. If the score barely moves, the blocking was
  never uBOL's.
- **Whether that switch is a switch.** The Blocking toggle was *off* in the UI; that six then applies no rule list of
  its own is exactly the kind of thing this file exists for. Same page with uBOL off and blocking off is the
  measurement: a high score with both off means something else is blocking and neither result means anything yet.
- **What kind of blocking it is.** `adblock-tester.com` counts requests, and `declarativeNetRequest` — which WebKit
  implements and six has watched blocking — is enough to score well. The part that was never in doubt is not the
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

The instrument is a three-file MV3 extension of our own, loaded with `SIX_EXTENSION=/path/to/unpacked`: a content
script that messages its background and writes the reply into `document.title`, a background that answers and then
calls `insertCSS` and `executeScript` at the same tab, and one read through `six --mcp`:

```js
return [document.title, window.__probe, getComputedStyle(document.body).backgroundColor]
```

Three values, four calls, one page. Errors land in `list_console_messages` and in the app's own log as
`[extensions] <name> reports …`. It has to be an ordinary page in an ordinary window: extensions do not run in
private browsing, and `six://` pages have no content scripts.
