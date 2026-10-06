# Tasks

Work that is specified and not started, one file per task, each written to be handed to a fresh session as it
stands: why, what is already measured, where to look, what "done" means. They came out of the wpt permission runs
of October 2026 ([permissions.md](../permissions.md#compatibility-web-platform-tests),
[page-scripts.md](../page-scripts.md)).

A task's file is deleted by the commit that finishes it; what was learned goes into the ordinary docs.

## In order

| # | task | what it changes |
|---|---|---|
| 2 | [browser/02-site-icons.md](browser/02-site-icons.md) | favicons that sometimes do not load; no script in the page for them |
| 3 | [browser/03-popups.md](browser/03-popups.md) | which `window.open` is a window and which a tab; dialogs and permissions in the window |
| 7 | [permissions/07-geolocation.md](permissions/07-geolocation.md) | geolocation for sites |
| 8 | [permissions/08-notifications.md](permissions/08-notifications.md) | site notifications |
| 11 | [browser/11-page-scripts-rest.md](browser/11-page-scripts-rest.md) | one pass: the calls that are still a gesture, the last script on every page, the Apple Pay experiment, `AdvancedRules` on or gone |
| 12 | [measure/12-one-sitting.md](measure/12-one-sitting.md) | one sitting of measurements: extensions, two WebMCP tests, fullscreen on a real site |
| 13 | [browser/13-small-things.md](browser/13-small-things.md) | one pass of six small things from the todo |
| 14 | [browser/14-waits-by-the-clock.md](browser/14-waits-by-the-clock.md) | one pass: three waits by the clock replaced by the event they stand in for, the first of them a race |

7 and 8 share a header and a delegate proxy: one after the other, never in parallel. 11 to 14 are each several small things meant for one session.

## Not tasks yet

- **Idle Detection** — WebKit does not implement `IdleDetector`; nothing to build until it does.
- **`MediaStreamTrack-getCapabilities`** — four subtests differ from Safari's CI because this Mac's camera reports
  no `facingMode` and CI's mock camera does. Closed without a change.

## Larger, and not specified yet

In [todo.md](../todo.md), each with its own plan or its own open question: passkeys and passwords
([passkeys.md](../passkeys.md), marked next up), sync through CloudKit ([sync.md](../sync.md)), images in
bookmarks, history pages in the store, web archives in Save As, a floating window, cosmetic rules inside frames,
ghost text in a field, a verb of one's own.

## Every task

- Debug Savoia only, in a throwaway home (`CFFIXED_USER_HOME`, as `scripts/permissions-wpt.py` does). The Release
  Savoia is Artem's browser: never killed, never touched.
- Measure before building, and say in the commit what was measured and what was only reasoned.
- wpt tests run as they are: no edited assertions, harness or tests.
- Commit when asked, never push.
