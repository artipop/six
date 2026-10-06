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
| 7 | [permissions/07-geolocation.md](permissions/07-geolocation.md) | geolocation for sites |
| 8 | [permissions/08-notifications.md](permissions/08-notifications.md) | site notifications |
| 11 | [browser/11-page-scripts-rest.md](browser/11-page-scripts-rest.md) | one pass: the calls that are still a gesture, the last script on every page, the Apple Pay experiment, `AdvancedRules` on or gone |
| 12 | [measure/12-one-sitting.md](measure/12-one-sitting.md) | one sitting of measurements: extensions, two WebMCP tests, fullscreen on a real site |
| 13 | [browser/13-small-things.md](browser/13-small-things.md) | one pass of six small things from the todo |
| 14 | [browser/14-waits-by-the-clock.md](browser/14-waits-by-the-clock.md) | one pass: three waits by the clock replaced by the event they stand in for, the first of them a race |
| 15 | [agents/15-agent-tools-to-chrome.md](agents/15-agent-tools-to-chrome.md) | an agent's tools brought up to Chrome's DevTools MCP — upload, dialogs, hover, drag — with as little script in the page as possible |
| 16 | [bookmarks/16-images-in-bookmarks.md](bookmarks/16-images-in-bookmarks.md) | a bookmark found by the words in its pictures; only if such pages get bookmarked |
| 17 | [browser/17-floating-window.md](browser/17-floating-window.md) | a tab as a small always-on-top window |
| 18 | [assistant/18-ghost-text-and-own-verbs.md](assistant/18-ghost-text-and-own-verbs.md) | a verb of one's own, then an answer shown in the field itself |
| 19 | [storage/19-history-pages.md](storage/19-history-pages.md) | search over pages that were read, not only saved |
| 20 | [extensions/20-extensions-next.md](extensions/20-extensions-next.md) | after task 12: the WebKit bug to file, extension pages inside the interface |
| 21 | [design/21-open-design-questions.md](design/21-open-design-questions.md) | the two switches in Configuration, the ring's arrows — options made concrete for Artem to pick |

7 and 8 share a header and a delegate proxy: one after the other, never in parallel. 11 to 14 are each several small things meant for one session. 15 to 21 came out of the todo: each is larger, and 16 and 21 start with a question to Artem.

## Not tasks yet

- **Idle Detection** — WebKit does not implement `IdleDetector`; nothing to build until it does.
- **`MediaStreamTrack-getCapabilities`** — four subtests differ from Safari's CI because this Mac's camera reports
  no `facingMode` and CI's mock camera does. Closed without a change.

## Plans that are documents of their own

- **Passkeys and passwords** — [passkeys.md](../passkeys.md). Marked next up in the todo; as much paperwork with
  Apple as code.
- **Sync through CloudKit, history first** — [sync.md](../sync.md).
- **Dictation: what is left** — the end of [speech.md](../speech.md).

## Still only in the todo

[todo.md](../todo.md) keeps what has no brief: what waits on Apple (web archives in Save As), Savoia's own WebKit
build, cosmetic rules inside frames (after task 11 decides the blocker's page half), the classifier for tab groups,
the nine WebMCP tests left, and a few smaller things.

## Every task

- Debug Savoia only, in a throwaway home (`CFFIXED_USER_HOME`, as `scripts/permissions-wpt.py` does). The Release
  Savoia is Artem's browser: never killed, never touched.
- Measure before building, and say in the commit what was measured and what was only reasoned.
- wpt tests run as they are: no edited assertions, harness or tests.
- Commit when asked, never push.
