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

4. **The two wpt tests that needed an opened window.** `window.open` returns a window now
   ([links.md](../../links.md#a-second-window)), so they may pass — or fail for a new reason: the window is a
   `WKWebView` of its own, and nobody has checked that the polyfill is installed in it.
   `./scripts/webmcp-wpt.py` (its stand is still under `savoia.localhost`, and it uses the dev build's own home:
   `--install-ca` with the dev Savoia quit, then launch with `SAVOIA_WEBMCP=1`). Update the nine-left list in
   [webmcp.md](../../webmcp.md#the-nine-wpt-tests-left) and the baseline.

## Windows a page opens

5. **Element fullscreen, then a navigation, on a real video site.** The fix
   (`BrowserTab.leaveElementFullscreen`) was checked on the wpt stand only. Artem does this one by hand: a video in
   fullscreen, then a link or "next" that navigates — the tab must not go blank.

## Done when

Each numbered line has a date and a result in the page it belongs to, and unmeasured.md is shorter.
