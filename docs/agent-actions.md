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
   ([accessibility.md](accessibility.md#toward-page-tools-derived-from-the-tree)). Mac only, and only with Savoia
   allowed under Accessibility.
4. **The page's elements one by one** — the DOM snapshot and the acting tools below. Every page has these, on every
   front.

An agent over MCP gets 2 and 3 through the same pair, `list_page_tools` and `call_page_tool`: a page's declared
tools when it has any, the derived ones when it has none. The elements are `page_snapshot` and the tools below. `run_page_task` chooses for it, at every step
([below](#run_page_task-the-routes)).

What is left when none of them works — a canvas (Sheets, Figma, Maps), a page whose controls have no names — is
[not built](#not-built).

## The acting tools

`page_snapshot`, `click`, `fill`, `select_option`, `press_key`, `scroll_page`, `hover`, `drag`, `wait_for`,
`handle_dialog`, `upload_file`, all `surfaces: .mcp`: an
ACP agent gets them through its own permission dialog, and the ⌘E line never gets a button pressed in answer to a
question. The page half is `Savoia/Tools/PageActionScript.swift`, the Swift half `Savoia/Tools/PageActions.swift`, the
tools themselves in `BrowserTools.swift`.

- **`click` is a mouse event, not a script.** The script finds the element, scrolls it into view and checks what
  covers it; the click itself is an `NSEvent` handed to the web view (`BrowserTab.click(atViewport:)`), so the page
  sees a trusted click with a user gesture — a button that opens a window or starts playback works. The scripts
  themselves run without a gesture ([page-scripts.md](page-scripts.md)). A page with no view on screen, and a
  `force` click through a cover, still get the scripted `click()`. `fill` sets the value from script, as before.
- **`press_key` is a key event too.** The script only gives the element the keyboard (`PageActionScript.focus`);
  the key is an `NSEvent` down and up handed to the web view (`WKWebView.press`, `Savoia/Browser/PageKeys.swift`),
  so the page sees trusted `keydown`, `keypress`, `input` and `keyup` and WebKit does the rest itself — Enter
  submits, Tab moves the focus across frames, a character lands in the field. `PageKey` is the table from the
  name in `KeyboardEvent.key` to a key code of the ANSI layout. A page with no view on screen, and a character
  the table has no key for (anything outside ASCII), still get the scripted events, which are not trusted and
  whose default actions are done by hand.
- **The script runs in Savoia's own content world** (`WKWebView.savoia`), as the readable-text extractor does
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

## Hover and drag: the pointer

Both are mouse events handed to the web view, and the script only finds the points, as it does for `click`
(`PageActions.hover`, `PageActions.drag`; `WKWebView.mouse` and `WKWebView.drop` in `Savoia/Browser/PageScripts.swift`).
Neither has a scripted fallback: a dispatched `mouseover` opens nothing CSS opens. A page whose view is in no
window is refused, with `focus_window` named.

- **A hover is a *dragged* event with no button down.** Measured, with Savoia not in front: `mouseMoved(with:)`
  on the `WKWebView` and WebKit's `_simulateMouseMove:` both gave the page nothing, and `mouseDragged(with:)` gave
  it an ordinary `mousemove` with `buttons: 0`, trusted `mouseover` and `mouseenter`, and a `:hover` that holds.
  The reasons are read from WebKit and not measured: `WKWebView` has no `mouseMoved:` of its own, the tracking area
  belonging to an observer; and a move with no button goes only to the scrollbars of a page whose window is not
  key, while a dragged event carries a button and is hit-tested anywhere. The page reads `buttons` from the system
  and not from the event, which is why it sees none. The pointer stays there until the next event; the hover ends
  when the agent acts elsewhere, or when the person's own pointer moves over the page.
- **`hover` aims twice.** What the pointer left may fold away and move the element, so the point is read again
  after the first event and the event repeated if it moved.
- **`drag` is down, eight dragged events along the line, up.** That is enough for whatever follows the pointer: a
  slider's thumb, a list sorted on `mousemove`. `buttons` is the system's here too, so a page that checks
  `event.buttons` during the move sees no button and lets go.
- **Drag-and-drop gets its drop from the destination's own methods, and no dragging session runs.** The page's
  `dragstart` fires on the real events, and WebKit then asks the view to begin a dragging session. Such a session
  is no use either way: with Savoia in the background it delivered nothing and never ended, and with Savoia in
  front it followed the person's pointer — the page got `dragenter` at the target and under the pointer in turn,
  and no `drop`. So for the length of an agent's drag the view declines to begin one (`dragsWithoutSession`:
  `WKWebView` is given a `beginDraggingSession` of its own at run time, which answers nil for that one view and
  is `NSView`'s for every other). `drag` watches the drag pasteboard: when its change count moves, the page has
  started a drag, the dragged events stop, and the web view is called as a session calls its destination —
  `draggingEntered`, `draggingUpdated` until the page's answer to `dragover` is back, `performDragOperation` —
  with a `PageDrop` that names the same pasteboard, then `draggedImage:endedAt:operation:` for `dragend`. A target
  that takes no drop gets `draggingExited`, and the tool fails saying so. A mouse-up follows either way; a browser
  under a hand sends none after a drop, and the page sees one here.
- **The snapshot lists `draggable="true"` elements**, with the role `draggable`, since a list item that can be
  dragged is rarely a control. A drop target with no control in it has no ref, and neither has an item sorted by
  pointer events alone: the agent names the nearest control inside it.
- `drag` takes two refs and no offsets, as Chrome's does: a slider is set with `fill` or the arrow keys.

Measured over `Savoia --mcp`, 7 October 2026, twice: in a throwaway home with Savoia in the background, and in
the dev build launched in front. The page had a CSS hover menu, a `mouseenter` tooltip, a list sorted on
`mousemove`, a `draggable` list, a drop target and an element that takes no drops. `hover` on the menu's button:
`:hover` matched, the submenu was displayed and its link was in the returned snapshot, and both still held 2.5 s
later; on the tooltip's button the tooltip's text appeared, and the menu folded. `drag` moved the first item of
each list behind the third, and put an item's `dataTransfer` text into the drop target, with `dragstart`,
`dragenter`, `drop`, `dragend` in that order and all trusted. The refusing element got `dragenter` and
`dragleave`, the source `dragend`, and the tool failed; a `click` and another `drag` after it worked. Each took
0.4–0.8 s. The first run in front, before sessions were declined, is where the two drag-and-drop cases failed. Artem
watched a later run in front: it went by fast, and nothing was left on screen.
The same destination calls with a pasteboard of two file URLs gave the page both files with their contents —
measured from the test driver, in the background, and not a tool. Not measured: a page inside a frame, and a
window known to be key — `document.hasFocus()` answered false in both runs.

## Dialogs and files: the delegate's door

`handle_dialog` and `upload_file` run no script of their own. A page's `alert`, `confirm`, `prompt` and file chooser
are requests to the tab's UI delegate (`PageDelegate`), and the tab keeps each one while it waits
(`PageDialog`, `PendingDialogs` in `Savoia/Browser/PageDialogs.swift`, as `BrowserTab.dialogs`).

- **A dialog is the person's and the agent's at once.** It is still a sheet that names its site; what changed is
  that the answer belongs to the `PageDialog` and not to the sheet, so whoever answers first wins and the sheet is
  taken down after an agent's answer. A dialog nobody is driving is answered by the person, as before. An agent may
  answer one it did not cause — through its own permission prompt, like every acting tool.
- **A page held by `alert`, `confirm` or `prompt` runs no script**, so a tool that reads the page would wait as
  long as the dialog does. `page_snapshot`, the acting tools, `wait_for` and `evaluate_javascript` race their work
  against a dialog opening (`PendingDialogs.racing`) and answer with the dialog instead — kind, message, site, and
  what a prompt holds. The work that lost goes on once the dialog is answered, unheard. The reading tools
  (`get_page_content` and the rest) are not wrapped and still wait.
- **`handle_dialog`**: `accept` or `dismiss`, and `text` for a prompt (without it, what the prompt holds). It also
  dismisses an open file chooser. There is no `beforeunload` in it: WebKit asks about that through SPI Savoia does
  not answer.
- **`upload_file`** takes `path` (one per line for a `multiple` input) and the `ref` that opens the chooser: the
  file input, which the snapshot lists as a button with `type=file` and the chosen file as its value, or the page's
  own Upload button over a hidden input. The files are left with the tab (`PendingDialogs.choosing`), the element
  gets the same real click `click` gives — a chooser opens only on a user gesture — and the delegate's
  `runOpenPanelWith` is answered with them: no panel is made. Five seconds without a chooser is a failure that says
  so. Without `ref` it answers a chooser that is already open, which is how an agent gets out of one it opened with
  a plain `click`. Files against the input's own terms — two for a single input, a folder for a file input — are
  refused by name and the page is told the chooser was cancelled.
  An automation tab is the exception: WebKit answers its chooser itself and the delegate is never asked, so the
  tool refuses there and names the protocol's command ([devtools.md](devtools.md#remote-automation)).

Measured over `Savoia --mcp` in a throwaway home, 7 October 2026, on a page of four buttons and three file inputs:
`confirm` accepted and dismissed read `true` and `false` in the page; `prompt` answered with a text, with its
default and dismissed read the text, the default and `null`; `alert` let the script after it run; a `confirm` raised
by `evaluate_javascript` came back as the dialog in 0.3 s instead of never. A file went into a plain input, into a
hidden input behind a button, and two into a `multiple` one, and the page read their contents back.

`SAVOIA_DIALOGS_SELFTEST=1` (`Savoia/Browser/DialogsSelfTest.swift`) runs the person's half and the sheets from
inside the app: each dialog is raised from a timer, its sheet is waited for, and it is answered by the sheet's own
OK or Cancel pressed with `performClick`, by Return posted to the sheet, or in code as an agent's answer; every step
logs what the page read and whether a sheet is still attached. On 8 October 2026 all fifteen steps passed: the
buttons of `confirm`, `prompt` and `alert`, a text put in the prompt's field, Return on `confirm` and `alert`, an
agent's answer taking the sheet down, the open panel cancelled and answered with a file, and a tab closed under
its `confirm`. The call that raises a dialog is not awaited there — WebKit holds its reply while the dialog is up.
The same day `upload_file` on squoosh.app, a real page with its input hidden behind a drop area: the editor opened
on the 177-byte image. What a posted key does not reach, and what only eyes can say, is in
[unmeasured.md](unmeasured.md#a-pages-dialogs-under-a-hand).

## Against Chrome's server

Tool for tool against `chrome-devtools-mcp`, whose list was read on 7 October 2026 and checked again against its
`docs/tool-reference.md` the next day. Two of Chrome's names in the built rows have no tool of their own here:
`fill_form` and `type_text` are `fill` called once per field, and `get_console_message` is a line of
`list_console_messages`.

| Chrome DevTools MCP | Savoia | |
|---|---|---|
| `take_snapshot` | `page_snapshot` | built |
| `click`, `fill`, `fill_form`, `press_key`, `type_text` | `click`, `fill`, `select_option`, `press_key` | built; click and keys are real events |
| `click_at` | — | not built: an agent answers with a ref, never coordinates |
| `handle_dialog` | `handle_dialog` | built; no `beforeunload` |
| `upload_file` | `upload_file` | built |
| `wait_for` | `wait_for` | built |
| `navigate_page`, `new_page`, `list_pages`, `select_page`, `close_page` | `navigate`, `open_window`, `list_workspaces`, `focus_window`, `close_window` | built |
| `evaluate_script` | `evaluate_javascript` | built; no user gesture |
| `take_screenshot` | `take_screenshot` | built; the visible part only |
| `list_console_messages`, `get_console_message`, `list_network_requests` | `list_console_messages`, `list_network_requests` | built, only while capture is on ([devtools.md](devtools.md)); status and timing, no headers or bodies |
| `list_webmcp_tools`, `execute_webmcp_tool` | `list_page_tools`, `call_page_tool` | built ([webmcp.md](webmcp.md)) |
| `hover`, `drag` | `hover`, `drag` | built; real events, and drag-and-drop through the destination's methods ([above](#hover-and-drag-the-pointer)) |
| `get_network_request` (headers, body) | — | not reachable |
| `emulate`, `resize_page` | — | not reachable |
| `performance_*`, `lighthouse_audit`, `get_css_styles`, `screencast_*`, the heap snapshot tools | — | not reachable |
| the extension and PWA tools | — | not built; extensions are installed by the person ([extensions.md](extensions.md)) |
| `list_3p_developer_tools`, `execute_3p_developer_tool` | — | not built: tools a page's own developer tooling registers with Chrome; nothing registers any with Savoia |

Not reachable means the Web Inspector protocol: a person can open the inspector on a tab, and nothing in Savoia
sends it a message ([devtools.md](devtools.md)).

## `run_page_task`: the routes

`/do …` or `do: …` on the ⌘E line (`сделай: …` too), and `run_page_task` over MCP. The loop is
`Savoia/PageTasks/PageTaskRunner.swift`: snapshot → decide → act → snapshot, with ceilings on steps (40) and on a page
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

- **System 1** — `Savoia/PageTasks/SystemOne.swift`, a client of one protocol, `/v1/systemone`, which both TypeSafe's
  hosted Jev and a local laya-browser server speak; which one is an address in `savoia://configuration` ▸ Assistant ▸
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
side-by-side run, environment variables override the settings: `SAVOIA_PAGETASK_ENDPOINT`, `SAVOIA_PAGETASK_KEY`,
`SAVOIA_PAGETASK_MODEL`, `SAVOIA_PAGETASK_THRESHOLD` (an empty endpoint is the model-only baseline). A refused key or an
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
open -na <Savoia.app> [--env SAVOIA_WEBMCP=1]
python3 scripts/agent-stand/tasks.py --label "model only"
```

`savoiamcp.py` finds this checkout's Debug build by the workspace path DerivedData records (the newest `Savoia-*` is often
another worktree's); `SAVOIA_APP` overrides it. `tasks.py` prints one row per task: steps, seconds, System 2 calls and
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

By hand, over `Savoia --mcp`, with only a goal and Savoia's tools (Claude Code, `claude -p`, 21 Sep): the stand's flights
in 18 turns ($0.40), its form in 11 ($0.19), httpbin.org/forms/post in 14 ($0.22), and live Google Flights, Zurich →
London, one-way, in 29 turns and 92 s ($0.98). One action with its snapshot is ~0.8 s; a snapshot alone ~0.2 s.

## Not built

- **Hands per source.** A derived tool acts through the DOM ref under its node. `AXUIElementPerformAction(AXPress)`
  and setting `AXValue` in the `--ax-read` child would press the way VoiceOver does, which matters exactly where the
  tree sees what the DOM walk does not (closed shadow roots, `ElementInternals`).
- **Real events, for canvases.** Sheets draws its grid in `<canvas>` and mostly ignores `isTrusted: false` events.
  `NSApp.postEvent` needs no Accessibility and produces trusted events (`Savoia/Input/KeySelfTest.swift`): the keyboard
  nearly covers Sheets (arrows, typing, Enter, ⌘C/⌘V); the mouse needs page → window coordinates through the column
  frame, page scroll and the Y flip — the one place to measure rather than reason. Refuse while the window is off
  screen or the row is animating.
- **Boundaries, before real events.** A profile as the sandbox (an "Agent" profile, and a ceiling — not a default —
  that the agent acts only there), and sites where acting is allowed, apart from where reading is, on the shape of
  `SitePermissions` (origin + profile → answer).
- **Frames.** The snapshot reads the main frame only.
- **Other fronts.** `PageActionScript` is plain JavaScript, but the tools and the runner are wired on Apple only.
