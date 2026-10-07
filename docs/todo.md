# TODO

A guide to what is not built: the order to take it in, and where each thing is written down. It holds no plans of
its own — a plan is a file in [tasks/](tasks/README.md) or a document beside this one. It stands in for a tracker
until the project has one.

## The order

The browser's core first, each step making the next one smaller.

| | what | where |
|---|---|---|
| 1 | **`handle_dialog` and `upload_file` for an agent** — the first two items of the agent-tools task, through the tab's own UI delegate, with no script in the page | [tasks/agents/15](tasks/agents/15-agent-tools-to-chrome.md) |
| 2 | **Web Inspector in Savoia's own window** | [tasks/devtools/22](tasks/devtools/22-web-inspector-in-savoia.md) |
| 3 | **`hover` and `drag` for an agent** — the rest of the same task, as real mouse events, each measured before it is promised | [tasks/agents/15](tasks/agents/15-agent-tools-to-chrome.md) |
| 4 | **Geolocation** | [tasks/permissions/07](tasks/permissions/07-geolocation.md) |
| 5 | **Site notifications** | [tasks/permissions/08](tasks/permissions/08-notifications.md) |
| 6 | **The rest of the scripts in pages**: the calls that are still a user gesture, the last script on every page, the blocker's page half as a setting that is off by default, and one experiment about Apple Pay | [tasks/browser/11](tasks/browser/11-page-scripts-rest.md) |
| 7 | **Waits by the clock** replaced by the events they stand in for — what is left; the first, a load to end, is done | [tasks/browser/14](tasks/browser/14-waits-by-the-clock.md) |
| 8 | **Small things**, seven of them: forget one site, a way home, a download that repeats, a user agent per site, every model in the welcome, a Help menu, grouping by meaning off for a new install | [tasks/browser/13](tasks/browser/13-small-things.md) |
| 9 | **Passkeys and passwords** — as much paperwork with Apple as code | [passkeys.md](passkeys.md) |

## Beside the order

Nothing here waits on the steps above, except where it says so.

| what | where |
|---|---|
| Measurements nobody has made: extensions' messaging and `scripting`, uBlock Origin Lite's control run, two WebMCP tests, fullscreen on a real site | [tasks/measure/12](tasks/measure/12-one-sitting.md) |
| Extensions after those measurements: what is left of the list now that a tab hands out its view and extension pages are tabs | [tasks/extensions/20](tasks/extensions/20-extensions-next.md) |
| A tab as a floating window | [tasks/browser/17](tasks/browser/17-floating-window.md) |
| The assistant: a verb of one's own, an answer shown in the field | [tasks/assistant/18](tasks/assistant/18-ghost-text-and-own-verbs.md) |
| A deep research saved as one self-contained file, sources and highlights inside | [tasks/assistant/26](tasks/assistant/26-research-as-one-file.md) |
| Deep research on a Mac with no agent: Savoia's own loop over the ⌘E model | [tasks/assistant/24](tasks/assistant/24-research-without-an-agent.md) |
| Search over pages that were read, not only saved | [tasks/storage/19](tasks/storage/19-history-pages.md) |
| EmbeddingGemma 2 as the embedder: one local model for text and pictures, to be compared with E5 on real bookmarks — decides how the next row is built | [tasks/bookmarks/25](tasks/bookmarks/25-embeddinggemma-2.md) |
| A bookmark found by the words in its pictures — only if such pages get bookmarked | [tasks/bookmarks/16](tasks/bookmarks/16-images-in-bookmarks.md) |
| Sync through CloudKit, history first | [sync.md](sync.md) |
| Dictation: Apple's own engine, a settings section, a key | the end of [speech.md](speech.md) |
| Two design questions with no answer chosen: the two switches in Configuration, the ring's three-key arrows | [tasks/design/21](tasks/design/21-open-design-questions.md) |

## Not built, and not planned

- **Apple Pay on sites.** A page has no `PaymentRequest`; it is not the Apple ID's region, and the cause is one
  experiment away ([tasks/browser/11](tasks/browser/11-page-scripts-rest.md), item 3).
- **Web Push.** `webpushd` serves only apps with a private entitlement
  ([permissions.md](permissions.md#geolocation-and-notifications-webkits-c-api-one-header-for-both)).
- **Cosmetic blocking rules inside frames** ([blocking.md](blocking.md#not-built-cosmetic-rules-inside-a-frame)).
- **Seven of WebMCP's nine failing wpt tests**, which wait for WebKit
  ([webmcp.md](webmcp.md#the-nine-wpt-tests-left)).
- **Idle Detection.** WebKit does not implement it.
- **The inspector's protocol for an agent** — request bodies, throttling, traces. A person gets them through the
  inspector's window (step 2); an app cannot reach the protocol for its own pages.
- **A WebKit build of Savoia's own.** Ruled out: system WebKit, used as far as it goes.

What waits on Apple to make something public, and how to notice when it does, is [api-watch.md](api-watch.md).
Claims nobody has watched happen are [unmeasured.md](unmeasured.md).
