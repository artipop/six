# 12. Things nobody has watched happen — one sitting

Measurements, not features. Each is a claim the docs make or nearly make, and each takes minutes once a Debug
Savoia is up in a throwaway home. The list and the reasoning are in [unmeasured.md](../../unmeasured.md); a line
leaves that file by being measured, in either direction, and by the page it came from being rewritten.

## Extensions

1. **uBlock Origin Lite's 96/100, and its control run.** Same profile with uBOL off; then with uBOL off and Savoia's
   own blocking off. A high score with both off means neither earlier result meant anything. Savoia's page half of
   blocking (`AdvancedRules`) is off by default now — say which way it was for each run.
2. **uBOL's per-tab half**: the badge number as the tab moves between sites, "disable on this site" surviving a
   reload, elements disappearing on `testpages.adblockplus.org/en/filters/element-hiding`.
3. **The four calls behind the compatibility verdict**: `runtime.sendMessage` from a content script,
   `tabs.sendMessage` to one, `scripting.executeScript`, `scripting.insertCSS`. The three-file MV3 probe is described
   in unmeasured.md; `SAVOIA_EXTENSION=/path` loads it. Then `ExtensionInstaller.permissionSupport` and the table in
   [extensions.md](../../extensions.md) say what was seen, and the guide follows.

## WebMCP

4. **The two wpt tests that needed an opened window** — measured on 7 October 2026: both pass
   ([webmcp.md](../../webmcp.md#the-nine-wpt-tests-left)). What is left there is the suite's newer surface, which
   is the polyfill's work and not a measurement.

## Windows a page opens

5. **Element fullscreen, then a navigation, on a real video site.** The workaround that left fullscreen first is
   gone with `WebPage`; that the view comes home by itself was checked on a stand page only. Artem does this one by hand: a video in
   fullscreen, then a link or "next" that navigates — the tab must not go blank.

## An agent's pointer

6. **`hover` and `drag` past the stand page**: a window known to be key, what a person sees, a frame, a real
   site, and the hover files of wpt. The page and the seven calls are described in unmeasured.md. The
   drag-and-drop files of wpt are not part of this sitting — they need the press moved to the web view first, and
   must not be run on the raw path while Artem is working.

## What Artem does, and what a session does

Items 5 and the watching half of 6 are a person's, and have pages: `./scripts/walk.sh`, the stations "Fullscreen
and picture-in-picture", "An agent's hand" and "On real sites" ([unmeasured.md](../../unmeasured.md)). Items 1 to
3 and the wpt half of 6 are a session's.

## Done when

Each numbered line has a date and a result in the page it belongs to, and unmeasured.md is shorter.
