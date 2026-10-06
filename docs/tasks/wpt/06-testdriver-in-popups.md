# 6. testdriver actions in a window the test opened

Teach the runner to find a frame that is not in the tab.

## Why

An action with a `context` is looked for only among the frames of the tab (`testdriver_in_context` in
`Savoia/Tools/TestDriver.swift`). In `storage-access-api` thirty actions answer `No frame of this window is …`, and
six files differ from Safari: `-cross-origin-iframe-navigation`, `-cross-site-sibling-iframes`,
`-sandboxed-iframe-allow-storage-access`, `-web-socket`, `storage-access-permission`,
`beyond-cookies.thirdPartyBlobStorage`.

The guess is that the frame lives in a window opened with `window.open` (`Savoia/Browser/ScriptedPopups.swift`).
**It has not been checked.**

## Order

1. Check the guess on one file — `requestStorageAccess-cross-site-sibling-iframes` — before changing anything.
2. If it holds: search the popups' views too, and send a click aimed there to that window's `WKWebView`, not to the
   tab's.

A storage-access grant cannot be taken back (`_grantStorageAccessForTesting:` only grants), so `prompt` and
`denied` are answered as done; a test that depends on taking one back will still differ.

## Done when

For each of the six files it is written down: gives Safari's result, or differs and why. Mind that Safari on
wpt.fyi itself moves between runs — do task 4 first, or compare with two of its runs.
