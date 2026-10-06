# Tasks

Work that is specified and not started, one file per task, each written to be handed to a fresh session as it
stands: why, what is already measured, where to look, what "done" means. They came out of the wpt permission runs
of October 2026 ([permissions.md](../permissions.md#compatibility-web-platform-tests),
[page-scripts.md](../page-scripts.md)).

A task's file is deleted by the commit that finishes it; what was learned goes into the ordinary docs.

## In order

| # | task | what it changes |
|---|---|---|
| 1 | [browser/01-scroll-interaction-state.md](browser/01-scroll-interaction-state.md) | scroll position kept by WebKit's own session state instead of two scripts |
| 2 | [browser/02-site-icons.md](browser/02-site-icons.md) | favicons that sometimes do not load; no script in the page for them |
| 3 | [browser/03-popups.md](browser/03-popups.md) | which `window.open` is a window and which a tab; dialogs and permissions in the window |
| 4 | [wpt/04-pinned-safari-baseline.md](wpt/04-pinned-safari-baseline.md) | the comparison with Safari stops moving when Safari's run does |
| 5 | [wpt/05-real-keys.md](wpt/05-real-keys.md) | `press_key` and testdriver's `send_keys` / `action_sequence` as real key events |
| 6 | [wpt/06-testdriver-in-popups.md](wpt/06-testdriver-in-popups.md) | testdriver actions aimed at a frame of a window the test opened |
| 7 | [permissions/07-geolocation.md](permissions/07-geolocation.md) | geolocation for sites |
| 8 | [permissions/08-notifications.md](permissions/08-notifications.md) | site notifications |
| 9 | [investigations/09-apple-pay.md](investigations/09-apple-pay.md) | why `PaymentRequest` is undefined — a cause, not a fix |
| 10 | [investigations/10-activation-at-load.md](investigations/10-activation-at-load.md) | why every loaded page reports `hasBeenActive` |

4 goes before the tasks that rewrite the baseline. 7 and 8 share a header and a delegate proxy: one after the
other, never in parallel.

## Not tasks yet

- **`AdvancedRules`** — the blocker's scriptlets and extended CSS are off behind `SAVOIA_ADVANCED_RULES=1` while
  Artem uses the browser without them. Back on, or gone, is his call.
- **Idle Detection** — WebKit does not implement `IdleDetector`; nothing to build until it does.
- **`MediaStreamTrack-getCapabilities`** — four subtests differ from Safari's CI because this Mac's camera reports
  no `facingMode` and CI's mock camera does. Closed without a change.

## Every task

- Debug Savoia only, in a throwaway home (`CFFIXED_USER_HOME`, as `scripts/permissions-wpt.py` does). The Release
  Savoia is Artem's browser: never killed, never touched.
- Measure before building, and say in the commit what was measured and what was only reasoned.
- wpt tests run as they are: no edited assertions, harness or tests.
- Commit when asked, never push.
