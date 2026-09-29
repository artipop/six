# Agents acting on a page

The rest of the catalog ([mcp.md](mcp.md), [agents.md](agents.md)) is about how an agent *reads* the browser. This is
about how it *acts*: fills a form, runs a search, presses a button — inside the person's signed-in session.

That session is the point. `BrowserState.dataStore(for:)` gives each window its profile's
`WKWebsiteDataStore(forIdentifier:)`, so `open_window` on a site the person is signed in to opens signed in: no key,
no OAuth, no app registered anywhere. A cloud agent (Operator, Browserbase) cannot do that and hands control back
for the password; a browser is the program the person is already signed in with.

## How an agent acts, best first

The rule, settled early and kept: **through the page's own API or its DOM, not a model looking at pixels.** A site's
own entry point is faster, survives a redesign and gives what the DOM does not have at all. If a vision path ever
exists, it is switched on **per site**, the way `SitePermissions` is, never by one switch for everything.

1. **The service's own MCP server**, connected in Apps — not a page at all ([mcp-apps.md](mcp-apps.md)).
2. **The tools the page declared** — WebMCP ([webmcp.md](webmcp.md)).
3. **Tools derived from the page's accessibility tree** — a form with its fields, a named control, a field
   ([accessibility.md](accessibility.md#toward-page-tools-derived-from-the-tree)). Mac only, and only with six
   allowed under Accessibility.
4. **The page's elements one by one** — the DOM snapshot and the acting tools below. Every page has these, on every
   front.

An agent over MCP gets 2 and 3 through the same pair, `list_page_tools` and `call_page_tool`: a page's declared
tools when it has any, the derived ones when it has none. The elements are `page_snapshot` and the tools below. `run_page_task` chooses for it, at every step
([below](#run_page_task-the-routes)).

What is left when none of them works — a canvas (Sheets, Figma, Maps), a page whose controls have no names — is
[not built](#not-built).

## The acting tools

`page_snapshot`, `click`, `fill`, `select_option`, `press_key`, `scroll_page`, `wait_for`, all `surfaces: .mcp`: an
ACP agent gets them through its own permission dialog, and the ⌘E line never gets a button pressed in answer to a
question. The page half is `six/Tools/PageActionScript.swift`, the Swift half `six/Tools/PageActions.swift`, the
tools themselves in `BrowserTools.swift`.

- **The script runs in six's own content world** (`WebPage.six`), as the readable-text extractor does
  ([architecture.md](architecture.md#page-side-scripts)): a page cannot redefine `querySelectorAll` or a getter to
  show the agent a button the person does not see, or reach the registry to aim a click elsewhere. It is also why the
  WebMCP polyfill, which patches `Element.prototype.matches` / `closest` and `HTMLFormElement.prototype.submit` in
  the page's world, does not touch the snapshot.
- **A ref is the node's identity, not its place in the list.** Borrowed from
  [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast): a `WeakMap` numbers every element the
  snapshot saw, a `Map` keeps the live node. The same element keeps `e12` across snapshots; a removed element's ref
  fails with "take a new snapshot" instead of landing on whatever took its place. The model answers with a ref —
  never a selector, coordinates or script — so nothing it says is executed.
- **Every action answers with the new snapshot**, as Playwright's MCP server does: the next thing an agent needs
  after a click is always to look, and one round trip is cheaper than two. Before it, a wait until the DOM stops
  changing (a `MutationObserver` count, two agreeing reads, 3 s ceiling), so a slow autocomplete shows its
  suggestions.
- **Typing goes through `execCommand('insertText')`**, not the `value` setter: WebKit runs it as real editing, so
  `beforeinput` / `input` arrive as from a keyboard and autocomplete opens. The setter is the fallback for fields
  that refuse editing (dates, masks).
- **`click` refuses when something covers the element**, and names it (`elementFromPoint` at the centre). A
  full-screen cookie banner otherwise eats the click silently.
- **Look-alikes get their row's text**: five "Select" buttons on a results page are one button to a model until each
  carries its flight and price.
- Open shadow roots are walked; closed ones and `ElementInternals` are not — the narrow difference from the
  accessibility tree measured in [accessibility.md](accessibility.md). Main frame only.
- `wait_for` is not a convenience: `callJavaScript` takes no `await`, so everything that waits is polled from Swift.

## `run_page_task`: the routes

`/do …` or `do: …` on the ⌘E line (`сделай: …` too), and `run_page_task` over MCP. The loop is
`six/PageTasks/PageTaskRunner.swift`: snapshot → decide → act → snapshot, with ceilings on steps (40) and on a page
that stopped changing (3).

At every step `PageTaskRoute.choose` asks what the page offers, in the order above:

- **The page's WebMCP tools**, when it declared any. The model may answer `CALL_TOOL` with the tool's name and its
  input as JSON. The call goes through `WebMCPStore.call` — the same gate as `call_page_tool`: the site is asked
  about once, anything not `readOnlyHint` per call — and the answer comes back fenced as the page's data.
- **Tools derived from the accessibility tree**, when WebMCP is on (the same switch the spark mark in the address
  bar waits for) and the tree's verdict is *good*. The tree is read for the eyes, the DOM snapshot is the hands:
  each node is matched to the smallest snapshot element whose box holds the node's middle (scaled by the zoom), and
  a node with nothing under it is dropped. A form becomes `FILL_FORM` with a JSON object of field name to value —
  text, a list's option, a checkbox's true or false, and `submit` — one step for what was a step per field; a
  named control or field is offered by its ref. A submit button whose name commits is not pressed. A refused
  Accessibility grant is believed for a minute, then asked again.
- **The elements**, always, below whatever was offered: a WebMCP page still has buttons its tools do not cover.

The trace names the route on each step (`via the page's tools (1)`), and the ⌘E line and MCP answer are that trace.

### Two deciders

- **System 1** — `six/PageTasks/SystemOne.swift`, a client of one protocol, `/v1/systemone`, which both TypeSafe's
  hosted Jev and a local laya-browser server speak; which one is an address in `six://configuration` ▸ Assistant ▸
  Page Tasks. One request asks for the operation and a target for every operation, and only the head for the chosen
  operation is used. It picks elements; it cannot call a page tool, so on a WebMCP page every step is System 2's.
- **System 2** — the assistant's model: a `LanguageModelSession`, or an **ACP agent** when the ⌘E line is set to
  one (Claude Code, paid for by a subscription already). The agent answers one JSON object and is told not to touch
  the page itself; the finished message is taken from the transcript, not the stream, and the JSON is found by
  trying brace spans until one parses and names an operation.

Rules, each put there by a run rather than by theory:

1. **System 2 writes every value.** A classifier produces no words.
2. **While System 2 is asked for a value, it may overrule the step.** It costs nothing, and it is most of the
   hybrid's accuracy: on the first run laya typed into a field under a cookie banner, and System 2 answered "close
   the banner first".
3. **System 1's `DONE` is never taken; the step after one that changed nothing goes up; the first step on a new page
   is System 2's.** All three are one failure: on the results page laya pressed "Select" on the first flight at
   0.97–0.98 — on a live site, booking — with no notion that the goal was met.
4. **A trusted step costs few tokens.** When System 1 chose the field and is sure, System 2 is asked only for the
   value — goal, title, the last four steps — not the page.

**Nothing that commits is pressed.** `PageTaskRunner.commits` (both languages) stops the run in front of a button that
pays, books, orders, subscribes or deletes, and says what is ready. A prompt could ask a language model for this; a
322M classifier has no notion of it, so the rule is in code.

### Trying Jev

The client already speaks `/v1/systemone`, so it is settings, not code: **Fast Model Server**
`https://api.typesafe.ai/v1/systemone`, **Model** `jev-latest`, a TypeSafe key, **Confidence Threshold** 0.9. For a
side-by-side run, environment variables override the settings: `SIX_PAGETASK_ENDPOINT`, `SIX_PAGETASK_KEY`,
`SIX_PAGETASK_MODEL`, `SIX_PAGETASK_THRESHOLD` (an empty endpoint is the model-only baseline). A refused key or an
unreachable endpoint is the trace's first line, not a silent model-only run.

## The stand

`scripts/agent-stand/`: `serve.py` serves the pages and appends everything they submit to `submitted.jsonl`, which is
what a run is checked against — never the agent's account of itself.

- `flights.html` — a delayed autocomplete, a calendar, a full-screen cookie banner, `+`/`−`, a `select`, a checkbox;
- `contact.html` — fields, a `select`, radios, consent, submit;
- `orders.html` — a lookup form that also declares `order_status` through WebMCP, and records which one was used;
- `results.html` — the goal is already met; a decider that presses anything fails.

```sh
python3 scripts/agent-stand/serve.py 8765 &
open -na <six.app> [--env SIX_WEBMCP=1]
python3 scripts/agent-stand/tasks.py --label "model only"
```

`sixmcp.py` finds this checkout's Debug build by the workspace path DerivedData records (the newest `six-*` is often
another worktree's); `SIX_APP` overrides it. `tasks.py` prints one row per task: steps, seconds, System 2 calls and
prompt characters, and how many steps were left to System 1 — the column that decides whether a fast decider saves
anything. The first `orders` run asks about the site `127.0.0.1` once.

**Measured**, System 2 Claude Code over ACP, all endings checked against `submitted.jsonl`:

| run | flights | contact | orders | results |
|---|---|---|---|---|
| model only, elements (23 Sep) | 14 steps, 34 s | 8, 15 s | — | 1, 1.8 s |
| + laya-browser v10s on MPS (23 Sep) | 14, 38 s — 1 of 13 kept | 9, 19 s — 1 of 7 | — | 1, 2.0 s |
| WebMCP off (27 Sep) | 16, 67 s | 8, 30 s | 3, 11 s — the form | 1, 4.0 s |
| WebMCP on, Accessibility granted (27 Sep, two rounds) | 14, 54–59 s | 6, 23–26 s — one `FILL_FORM` | 2, 8 s — `order_status` | 1, 3.9–4.1 s |
| same, forms with lists, checkboxes and `submit` (28 Sep) | 14, 83 s | 4, 18 s | 2, 9 s | 1, 3.8 s |

With laya-browser v10s there is no saving: it kept one step in thirteen, so the model is called almost every step
anyway and its own 0.35–1.3 s on MPS come on top. Three mistakes on this side were found on the way: the request
lacked the role and current value that jev-ultrafast sends; the questions were paraphrased, while laya-browser was
fine-tuned on `jev_ultrafast/questions.py` verbatim, which for a 322M checkpoint is part of the input; and the agent's
answer was assembled from the stream, which once arrived as `{"operation": "CLe32", "value": "",ICK", "ref": "`.

Reading the transcript did not cure that last one: a handful of runs on 27 September still ended on
`"CLIC1", "value": "",K"`. The transcript itself was shuffled — `JSONRPCConnection` started a `Task` per
notification, so message chunks reached the store in no particular order, and a turn's response could be read
before its last chunk. Notifications are now handled in the reader, in order; all twenty-one stand runs after that
ended as `submitted.jsonl` says they should.

Untried: Jev live (needs a key) and
[ShaunSpark/laya-mind2web-browser-agent](https://huggingface.co/ShaunSpark/laya-mind2web-browser-agent) (671
Mind2Web examples, no server for this protocol) are untried.

By hand, over `six --mcp`, with only a goal and six's tools (Claude Code, `claude -p`, 21 Sep): the stand's flights
in 18 turns ($0.40), its form in 11 ($0.19), httpbin.org/forms/post in 14 ($0.22), and live Google Flights, Zurich →
London, one-way, in 29 turns and 92 s ($0.98). One action with its snapshot is ~0.8 s; a snapshot alone ~0.2 s.

## Not built

- **Hands per source.** A derived tool acts through the DOM ref under its node. `AXUIElementPerformAction(AXPress)`
  and setting `AXValue` in the `--ax-read` child would press the way VoiceOver does, which matters exactly where the
  tree sees what the DOM walk does not (closed shadow roots, `ElementInternals`).
- **Real events, for canvases.** Sheets draws its grid in `<canvas>` and mostly ignores `isTrusted: false` events.
  `NSApp.postEvent` needs no Accessibility and produces trusted events (`six/Input/KeySelfTest.swift`): the keyboard
  nearly covers Sheets (arrows, typing, Enter, ⌘C/⌘V); the mouse needs page → window coordinates through the column
  frame, page scroll and the Y flip — the one place to measure rather than reason. Refuse while the window is off
  screen or the row is animating.
- **Boundaries, before real events.** A profile as the sandbox (an "Agent" profile, and a ceiling — not a default —
  that the agent acts only there), and sites where acting is allowed, apart from where reading is, on the shape of
  `SitePermissions` (origin + profile → answer).
- **Frames.** The snapshot reads the main frame only.
- **Other fronts.** `PageActionScript` is plain JavaScript, but the tools and the runner are wired on Apple only.
