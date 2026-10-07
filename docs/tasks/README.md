# Tasks

Work that is specified and not started, one file per task, each written to be handed to a fresh session as it
stands: why, what is already measured, where to look, what "done" means. They came out of the wpt permission runs
of October 2026 ([permissions.md](../permissions.md#compatibility-web-platform-tests),
[page-scripts.md](../page-scripts.md)).

A task's file is deleted by the commit that finishes it; what was learned goes into the ordinary docs.

## The files

The order to take them in, and what is not a task at all, is [todo.md](../todo.md). This is only the list.

| file | what |
|---|---|
| [permissions/07-geolocation.md](permissions/07-geolocation.md) | Geolocation for sites |
| [permissions/08-notifications.md](permissions/08-notifications.md) | Site notifications |
| [browser/11-page-scripts-rest.md](browser/11-page-scripts-rest.md) | The rest of the scripts in pages — one pass |
| [measure/12-one-sitting.md](measure/12-one-sitting.md) | Things nobody has watched happen — one sitting |
| [browser/13-small-things.md](browser/13-small-things.md) | Small things — one pass |
| [browser/14-waits-by-the-clock.md](browser/14-waits-by-the-clock.md) | Waits by the clock that have an event — one pass |
| [agents/15-agent-tools-to-chrome.md](agents/15-agent-tools-to-chrome.md) | An agent in Savoia can do what one in Chrome can |
| [bookmarks/16-images-in-bookmarks.md](bookmarks/16-images-in-bookmarks.md) | Finding a bookmark by what is in its pictures |
| [browser/17-floating-window.md](browser/17-floating-window.md) | A tab as a small window that floats |
| [assistant/18-ghost-text-and-own-verbs.md](assistant/18-ghost-text-and-own-verbs.md) | The assistant: an answer in place, and a verb of one's own |
| [storage/19-history-pages.md](storage/19-history-pages.md) | Search over what was read, not only what was saved |
| [extensions/20-extensions-next.md](extensions/20-extensions-next.md) | Extensions: after the measurement |
| [design/21-open-design-questions.md](design/21-open-design-questions.md) | Two questions with no answer chosen |
| [devtools/22-web-inspector-in-savoia.md](devtools/22-web-inspector-in-savoia.md) | Web Inspector in Savoia's own window |
| [assistant/24-research-without-an-agent.md](assistant/24-research-without-an-agent.md) | Deep research for a Mac with no agent, and a run saved as one file |
| [bookmarks/25-embeddinggemma-2.md](bookmarks/25-embeddinggemma-2.md) | EmbeddingGemma 2 as the embedder |

## Every task

- Debug Savoia only, in a throwaway home (`CFFIXED_USER_HOME`, as `scripts/permissions-wpt.py` does). The Release
  Savoia is Artem's browser: never killed, never touched.
- Measure before building, and say in the commit what was measured and what was only reasoned.
- wpt tests run as they are: no edited assertions, harness or tests.
- Commit when asked, never push.
