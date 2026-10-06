# 5. Real key presses

Make key presses real events, the way the click already is.

## Why

The agent's `click` and testdriver's are an `NSEvent` handed to the `WKWebView`
(`BrowserTab.click(atViewport:)` in `Savoia/Browser/PageScripts.swift`): the page sees a trusted event. The
agent's `press_key` still dispatches synthetic `KeyboardEvent`s from a script (`PageActionScript.press`), and in
testdriver `send_keys` and `action_sequence` answer `not implemented` — seven wpt files fail on that
([permissions.md](../../permissions.md#compatibility-web-platform-tests), the table of causes).

## Where to look

- `Savoia/Tools/PageActions.swift`, `PageActionScript.swift`, `TestDriver.swift`.
- `scripts/permissions-wpt.py`, the function `act`.
- How wptrunner takes these actions apart: `~/Library/Caches/savoia-wpt/tools/wptrunner/wptrunner/executors/actions.py`.
- Keys in Savoia — AGENTS.md: `KeySelfTest`, compare `KeyModifiers` and nothing else, letters by key code.

## Done when

- `press_key` gives the page a trusted `keydown` (check `isTrusted` over `Savoia --mcp`).
- `clipboard-copy-selection-line-break` (four addresses), `paste-on-detaching-iframe` and the two
  `focus-without-user-activation-disabled-*` files give Safari's result, or the reason they do not is named.
- The baseline is updated, and [agent-actions.md](../../agent-actions.md) says what `press_key` is now.
