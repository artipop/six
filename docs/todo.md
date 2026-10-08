# TODO

A guide to what is not built: the order to take it in, and where each thing is written down. It holds no plans of
its own — a plan is a file in [tasks/](tasks/README.md) or a document beside this one. It stands in for a tracker
until the project has one.

## The order

The browser's core first, each step making the next one smaller.

| | what | where |
|---|---|---|
| 1 | **Waits by the clock** replaced by the events they stand in for — what is left; the first, a load to end, is done | [tasks/browser/14](tasks/browser/14-waits-by-the-clock.md) |
| 2 | **Small things**, seven of them: forget one site, a way home, a download that repeats, a user agent per site, every model in the welcome, a Help menu, grouping by meaning off for a new install | [tasks/browser/13](tasks/browser/13-small-things.md) |
| 3 | **Passkeys and passwords** — as much paperwork with Apple as code | [passkeys.md](passkeys.md) |

## Beside the order

Nothing here waits on the steps above, except where it says so.

| what | where |
|---|---|
| Playwright: it speaks WebDriver BiDi, which the WebDriver server does not; three questions before a line is written | [tasks/devtools/33](tasks/devtools/33-playwright-bidi.md) |
| WebDriver's `pointerMove` hovers nothing in 24 of 85 wpt hover files that Safari passes | [tasks/devtools/34](tasks/devtools/34-hover-under-webdriver.md) |
| A tab as a floating window | [tasks/browser/17](tasks/browser/17-floating-window.md) |
| Apple Pay on sites: WebKit keeps `PaymentRequest` from an app's view unless an SPI switch is set; whether a payment then goes through takes a card and a hand | [tasks/browser/32](tasks/browser/32-apple-pay-switch.md) |
| WebKit's Paste menu, which an agent's click brings up over whatever app is in front | [tasks/permissions/30](tasks/permissions/30-paste-menu-over-another-app.md) |
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

- **Web Push.** `webpushd` serves only apps with a private entitlement
  ([permissions.md](permissions.md#what-savoia-still-cannot-ask-for)).
- **Cosmetic blocking rules inside frames** ([blocking.md](blocking.md#not-built-cosmetic-rules-inside-a-frame)).
- **Seven of WebMCP's nine failing wpt tests**, which wait for WebKit
  ([webmcp.md](webmcp.md#the-nine-wpt-tests-left)).
- **Idle Detection.** WebKit does not implement it.
- **The inspector's protocol for an agent** — request bodies, throttling, traces. A person gets them through the
  inspector's window ([devtools.md](devtools.md#web-inspector)); an app cannot reach the protocol for its own pages.
- **A WebKit build of Savoia's own.** Ruled out: system WebKit, used as far as it goes.

What waits on Apple to make something public, and how to notice when it does, is [api-watch.md](api-watch.md).
Claims nobody has watched happen are [unmeasured.md](unmeasured.md).
