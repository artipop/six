# The accessibility tree as the agent's eyes

View ▸ Accessibility Overlay (`⌥⌘A`) draws WebKit's accessibility tree over the focused window's page, and
`get_accessibility_tree` hands the same read to an agent as numbered lines. Mac only.

The tree is read by a second process, `Savoia --ax-read <pid>`, which Savoia starts itself: Savoia asking *itself* through
`AXUIElement` deadlocks the browser the moment the permission is given ("Why a second process" below).

The user-facing account is
[guide/accessibility.md](guide/accessibility.md); the plan for acting on what is seen is
[agent-actions.md](agent-actions.md).

| file | what it does |
|---|---|
| `Savoia/Accessibility/PageAccessibilityReader.swift` | `Savoia --ax-read`: the walk, `AXUIElement` calls → `AXPageSnapshot`, plain `Codable` values |
| `Savoia/Accessibility/AXReadProcess.swift` | the browser's side: starts the reader, one JSON line each way over a pipe, the watchdog, the idle stop |
| `Savoia/SavoiaApp.swift` | `SavoiaMain` hands `--ax-read` to the reader before AppKit is touched, as it does `--mcp` |
| `Savoia/Accessibility/DerivedPageTools.swift` | whether a reading is good enough to make tools of, and the tools it would make |
| `Savoia/Views/DerivedToolsButton.swift` | the mark for them in the address field, beside WebMCP's; `AddressBar` holds the reading |
| `Savoia/Accessibility/AccessibilityOverlay.swift` | the model (`AccessibilityOverlay.shared`), placing the snapshot over the web view, the outline for a model, and the SwiftUI layer |
| `Savoia/Input/WebViewResponder.swift` | `webView(for:)` — the pane's `WKWebView`, which is the only way to know where on screen a `WebPage` is |
| `Savoia/Views/TilingStripView.swift` | mounts `AccessibilityOverlayView` over the focused pane |
| `Savoia/Views/MacCommands.swift` | the View menu toggle |
| `Savoia/Tools/BrowserTools.swift` | `get_accessibility_tree` (`surfaces: .mcp`) |

## Why the accessibility tree and not the DOM

The DOM says what the markup says. The accessibility tree is what the engine *concluded* from it: ARIA roles and
names applied, `aria-hidden` subtrees gone, a label resolved from wherever it came from, a `div` with a click handler
turned into something that answers `AXPress` — plus, per element, the list of what it actually answers. That is the
vocabulary a person with a screen reader drives the page in, and the one a well-made site has already been tested
against. It is computed in the engine, out of the page's reach: a page cannot redefine a getter to show the agent a
button a person does not see. The DOM walk in [agent-actions.md](agent-actions.md#the-acting-tools)
stays the fallback for everything this cannot do — no permission, and the fronts that are not the Mac.

## Why `AXUIElement`, and why that takes a permission

Checked in WebKit's source (`Source/WebKit/UIProcess/mac/WebViewImpl.mm`, September 2026), not reasoned:

- The tree lives in the **web content process**. In this process `WKWebView` reports itself as an `AXGroup` whose one
  child is `m_remoteAccessibilityChild` — an `NSAccessibilityRemoteUIElement` made with `initWithRemoteToken:` from a
  token the web process sent. Even `accessibilityHitTest:` returns that element, whatever the point.
- That remote element is resolved by the accessibility runtime on the **client's** side, by talking to the web
  process. So the NSAccessibility protocol asked in-process stops at a token, and the client API — `AXUIElement` —
  is the one that crosses. macOS allows a process that API only once Privacy & Security ▸ Accessibility lists it,
  **including when the process it asks is itself**: an untrusted call answers `kAXErrorAPIDisabled`.
- `WebPage` has no accessibility API at all. `WKWebView` has `_retrieveAccessibilityTreeData:` — but it is in
  `WKWebViewTestingMac.mm`, WebKit's test SPI, and it returns a dump for layout tests, without the geometry or the
  actions an overlay needs.
- The first accessibility question the web view is asked (anything but parent and position) runs
  `enableAccessibilityIfNecessary`, which sets `AccessibilityMode::MainThread` on web content processes. From then on
  WebKit keeps an accessibility tree up to date for the pages it serves — a cost the pages did not pay before the
  overlay was first turned on, and one worth measuring on the 8 GB Mac.

**The second point is measured, not only read.** A build logged what the web view's in-process child answers for
`AXRole` and `AXChildren` through the old `accessibilityAttributeValue:`: `[]`. The in-process side really does stop
at the token, and the client API really is the only way in; the probe is gone now that it has answered.

## The read

The browser owns the request and nothing else. `AccessibilityOverlay.read` works out the middle of the pane's visible
part and that visible part itself, both in accessibility coordinates, and hands them with a limit to
`AXReadProcess`, which writes them as one JSON line (`AXReadRequest`) to the child's stdin and reads one
`AXPageSnapshot` line back from its stdout.

- **Started on demand**, from `Bundle.main.executableURL` with `--ax-read <Savoia's pid>`, on the first read.
- **Kept while reads keep coming** — the overlay reads every few seconds. The child leaves by itself after 30 s
  without a request (`poll` on stdin), and on end of file, which is what happens when Savoia quits. A timer on the
  browser's side was tried first and measurably did not fire; the child owning its own end has nothing to miss.
- **A watchdog of 8 s** per answer. The child cuts its own walk at 5 s and says it was truncated, so a child past 8 s
  is stuck; it is killed, the read answers "did not answer in time", and the next read starts a new one.
- **A reused child that has gone, or answers "not trusted", is replaced once.** It may have just left on its own;
  and a process keeps the answer to `AXIsProcessTrusted` it was started with, so the child the overlay's first
  press launched stays refused after the person switches Savoia on — measured, and so is the replacement, with no
  restart. **Savoia itself keeps its answer too**, so nothing that decides whether to read asks Savoia's own
  `AXIsProcessTrusted`: the child's answer is the one that counts, and a refusal is believed for a minute.

In the child, `PageAccessibilityReader.read(pid:at:visible:limit:)`:

1. `AXUIElementCopyElementAtPosition` on `AXUIElementCreateApplication(pid)` at the middle of the visible part.
2. Up the `AXParent`s to the **outermost** `AXWebArea` — an iframe is a web area of its own — or, when the hit test
   stopped at the web view's own group, a short breadth-first search down from where it stopped.
3. If that found nothing, or a web area that misses the visible part, **every web area of the app, and the one
   covering most of the visible part**. The rail keeps off-screen columns as web areas too, so "the first web area"
   is a lottery — the probe once walked the neighbouring column's page — and a split puts two on screen at once.
4. Depth-first from there, children pushed in reverse so the numbers come out in document order. Per element, one
   `AXUIElementCopyMultipleAttributeValues` for role, subrole, role description, title, description, value,
   placeholder, `AXDOMIdentifier`, position, size, enabled, focused and children; `AXUIElementCopyActionNames`; and,
   for the roles that can have one, whether `AXValue` is settable.
5. A subtree whose box has a size and misses the visible part (plus 40 pt) is not walked; a zero-size box is walked,
   because WebKit gives some containers none while their children are on screen. `AXStaticText` is not descended
   into. The walk stops at 2 500 elements or 5 s.
6. An element with no title or description takes its name from the text inside it, the way a screen reader reads a
   link.

A messaging timeout of 1.5 s is set on the system-wide element and on the application's, so a busy web process costs
a missing subtree instead of a stalled read. **If the first read finds no web area, or fewer than three elements, it
is read once more 400 ms later**: WebKit builds a page's tree when first asked for one. Measured on Wikipedia right
after the column was focused: the first ask answered "no web area", the second 265 elements.

**Kinds**, for colour and for the outline: *control* (buttons, links, checkboxes, pop-ups, sliders… and anything
answering `AXPress`/`AXIncrement`/`AXPick`/`AXConfirm`), *field* (text fields, text areas, combo boxes, search
fields, or a settable value), *landmark* (`AXLandmark*` subroles, dialogs, articles), *heading*, *image*, *text*,
*other*. `AXScrollToVisible` and `AXShowMenu` are not listed as verbs: WebKit gives them to every element.

## Placing it over the page

Accessibility counts from the top-left of the primary screen, y down; AppKit from its bottom-left, y up. Each box is
flipped into AppKit's screen space, taken into the window with `convertFromScreen`, into the web view with
`convert(_:from: nil)`, and flipped again if the view is not flipped. The result is in the web view's own points,
which are the overlay's, because the overlay is laid over exactly that view. The view's size at reading time is kept,
and the canvas scales by it if the pane has changed size since.

A snapshot is a picture of a moment. While the overlay is on, `follow` asks the page for `scrollX`, `scrollY`,
`innerWidth`, `innerHeight` and `readyState` every 500 ms (in Savoia's world, from the live page only — the overlay must
never be what builds a page). When they change, the boxes fade to 20 %; once two polls agree, the tree is read
again. A still page is read again every 5 s, for DOM changes. The task belongs to the view: moving the focus or
turning the switch off cancels it.

The boxes and labels are one `Canvas` — a page has hundreds of elements. Labels are placed greedily, controls first,
and skipped where they would cover one already placed. The canvas is `accessibilityHidden`: otherwise the next hit
test lands on the overlay instead of the page under it. The legend is `HostedOverlay`, because SwiftUI drawn over a
`WKWebView` never sees the mouse.

## For a model

`get_accessibility_tree(window_id?, include_text?, max_nodes?)`:

```
[1] document "Example Domain" @0,0 1280×720
  [4] heading level 1 "Example Domain" @320,133 640×38
  [9] link "More information..." — press @320,261 150×18
```

Roles are ARIA's (`button`, `textbox`, `navigation`), not AppKit's and not the system's localized ones: a model knows
the first vocabulary. Groups that are only structure are left out and their children pulled up a level. The numbers
are valid until the next read. The acting tools of [agent-actions.md](agent-actions.md) take the DOM snapshot's refs
instead; `run_page_task` reads both and matches them by box ([Used by page tasks](#used-by-page-tasks)). A
read done for the tool lands in the overlay too, so with the overlay on, the person sees what the agent was just
given.

The window must be on screen: the tree is read from what is displayed, and the tool says `focus_window` rather than
reading a pane that is off the edge of the rail.

## Why a second process

The first build read the tree from inside Savoia (16 September 2026). Without the permission it refused politely; **with
the permission granted, the first read deadlocked the browser.** Reproduced twice: once by turning the overlay on
with `⌥⌘A`, once by calling `get_accessibility_tree` over `Savoia --mcp` with no window and no menu involved. The app
stayed alive at 0% CPU and answered nothing — no MCP, no clicks — and only a kill ended it.

`sample` says the same thing both times. The thread that serves accessibility questions *inside Savoia* suspends
another thread of Savoia to answer, and that thread is holding SwiftUI's update lock:

```
main thread   UpdateGroup.begin() → _MovableLockLock → _pthread_mutex_firstfit_lock_wait → __psynch_mutexwait
HIE: … thread SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION (in HIServices) → thread_suspend
```

So the lock is never given back and the main thread waits for it forever. Nothing in `PageAccessibilityReader` is
wrong in itself — the read is already off the main thread, with a 1.5 s messaging timeout — because the suspension
is done by the system, at a point of its choosing, in a process that is asking *itself*. That is the part that has
to change: the question has to come from outside Savoia.

### Asked from outside instead — measured, and it works

`~/sources/angels/axprobe` (outside this repo) is a small `.app` that asks *another* process for its tree, plus
`stand/ax-stand.html`, ten cases where the two readings can disagree, and `stand/domdump.js`, the same page read
the other way — roles from `role` and the tag, names from the obvious attributes, boxes from
`getBoundingClientRect()`. A `.app` rather than a bare binary because a command run from a shell is answered for
by the terminal, and the grant would land there.

**What the tree holds that a DOM walk cannot get**, on the stand in Safari (the same engine, Savoia not involved):

| the case | the accessibility tree | the DOM walk in the page |
|---|---|---|
| a **closed** shadow root | its button and field are there | nothing: `shadowRoot` is `null` |
| light DOM slotted into a shadow tree | the button is named "Slotted label" | the button has no name |
| `aria-hidden`, `role=presentation`, `inert` | all three gone | all three present, unless the walk climbs every ancestor |
| semantics from `ElementInternals` | `AXCheckBox (AXSwitch) "Custom switch"` | an element with no role at all |
| `<canvas>` with fallback content | the button inside it | a canvas, and nothing in it |
| an iframe | a web area of its own, with its button | not entered: another document |
| `aria-labelledby`, `<label for>` | assembled by the engine | the same answer — this part JS can do |
| what an element answers to | `press`, `increment`, `pick`… per element | nothing: the DOM does not say |

So four of the ten cases are not "harder" from inside the page, they are unreachable. That is what the
permission buys.

**And the deadlock is specific to a process asking itself.** `axprobe` read the same page inside a running Savoia
with this branch's build: 400 elements in 0.17–0.40 s, closed shadow root included, three times in a row, and
Savoia answered over MCP immediately after each read and went on working. A Wikipedia article came back as
1 889 elements in 0.65 s. Nothing suspended, nothing hung.

What the probe learned about finding the page and asking twice is in "The read" above.

**Whose permission is it?** Five shapes, measured against a running build with Savoia allowed in
Privacy & Security ▸ Accessibility and nothing else granted:

| who calls `AXIsProcessTrusted` | launched by | trusted |
|---|---|---|
| a separate binary in `Contents/Helpers` | Savoia | **no** |
| the same binary re-signed with Savoia's identifier | Savoia | **no** |
| **Savoia's own executable, `Savoia --ax-read <pid>`** | Savoia | **yes** |
| Savoia's own executable, same arguments | a shell | **no** |
| **an XPC service in `Contents/XPCServices`** | Savoia, through `NSXPCConnection` | **yes** |

TCC's log explains every line. A request is attributed up a chain — `AttributionChain:
responsible={… identifier=org.deffun.savoia.dev …}`, `AUTHREQ_SUBJECT: subject=org.deffun.savoia.dev` — so who
launched it decides whose permission is asked for, which is why the same binary run from a terminal is refused:
there the responsible process is the terminal. And the grant is tied to the code that was allowed
(`matchesCodeRequirement: … cdhash …`), which is why a *different* binary is refused even with Savoia responsible.
Re-signing the helper with Savoia's identifier does not help: under an ad-hoc signature the requirement is the code
hash.

**An XPC service inside the bundle is trusted**, which is the tidiest of the shapes and the one Apple's own
tooling produces. The measurement went only that far: the service reported `trusted: true`, and then asked its
parent — which is `launchd`, since an XPC service is started by the system rather than by the app, so Savoia's pid
has to be handed to it over the connection. Reading a *given* process is the same `AXUIElement` call the outside
probe already makes against Savoia, so nothing else is expected to differ; it has not been run end to end.

So there are two workable shapes rather than one: an XPC service, or Savoia spawning its own executable with a flag
the way `--mcp` already does. Both are one checkbox, both are a second process, which is all the deadlock needs.

**Signing, since the probe lost its grant twice.** That is ad-hoc signing, not something helpers do: with no Team
ID, TCC has only the code directory hash to key the grant to, and every rebuild produces a new one. Signed with a
Developer ID identity, the grant is keyed to the designated requirement — team plus bundle id — and survives
updates. Savoia is ad-hoc signed today, Debug *and* the Release in `/Applications`, so this is a thing to fix before
any of it ships.

The other half is already right: **App Sandbox is off** (`Savoia/Savoia.entitlements` says why — the ACP layer spawns
the user's own toolchain), and it has to be, because a sandboxed process cannot be an accessibility client at all.

### Why `Savoia --ax-read`, and not the XPC service

Both shapes are one checkbox; the choice is about what else each one brings.

- **It already has a pattern here.** `Savoia --mcp` is the same binary in a second role, switched in `SavoiaMain` before
  AppKit is touched. `--ax-read` is one more line there, and the reader is the file it always was.
- **One bundle, one signature, one target.** An XPC service is a target of its own in `project.pbxproj`, a bundle of
  its own under `Contents/XPCServices`, signed separately, and an `Info.plist` of its own — for macOS only, with an
  iOS exclusion to keep it out of the other scheme. The grant is keyed to a code hash under ad-hoc signing, and
  every bundle is another one to keep in step.
- **Nothing XPC gives is needed.** The exchange is one request and one answer of plain values, which a pipe and
  `JSONEncoder` carry; `launchd`'s lifecycle management is replaced by thirty lines that start, watch and stop one
  `Process`. And the XPC service's measurement went only as far as `trusted: true` — `--ax-read` has now read pages
  end to end.

What `--ax-read` costs instead: the child is a whole Savoia executable in memory (it never touches AppKit, so it stays
small, but it maps everything), and it is only Savoia in macOS's eyes when Savoia launches it — the same executable run from
a shell is refused, which is also why it cannot be tested from a terminal with the permission on.

## What was checked, as built

Debug, macOS 27, 27 September 2026, one build throughout (a rebuild costs the grant):

- **Without the permission** the tool answers "Savoia is not allowed to use macOS accessibility…" in 0.16–0.35 s, the
  child is reused between calls, and Savoia goes on answering over MCP.
- **With the permission**, over `Savoia --mcp`: example.com, 8 elements in 279 ms; Wikipedia's *Accessibility*, 265
  elements in 84 ms on the visible part, after the "no web area" first ask above; the stand, 32 elements in 55 ms,
  the closed shadow root's button and field and the slotted "Slotted label" among them. Every call answered in
  0.16–0.6 s, and `list_workspaces` straight after each.
- **`⌥⌘A` three times** on the stand, on, off, on, with a scroll: Savoia alive, the boxes on the elements (by eye),
  and MCP answering with the overlay on.
- A child started before the grant stayed refused after it — which is what the "replaced once" rule is for. A
  second build, granted with a child already running, read the stand at the first call.

## Still not measured

- the boxes in a split, a window half off the rail, page zoom;
- the memory of the idle child on the 8 GB Mac;
- whether the overlay's own prompt and the legend's button reach the right Settings pane.

## Toward page tools derived from the tree

[webmcp.md](webmcp.md) is a page declaring tools for agents; this tree is the page as the engine understood it,
whether or not it declared anything. The two meet in the middle, and the aim is that everything built for WebMCP —
`list_page_tools` / `call_page_tool`, the ⌘K assistant's tools, the gate, the mark in the address field — carries
derived tools too, without a second catalog.

**The accessibility tree is the first source, not the only one.** A DOM walk (the fallback in
[agent-actions.md](agent-actions.md), and the only route on Linux, Windows and iOS today) and a vision model reading a
screenshot are the next ones. So the seam is a snapshot of *page elements* — role, name, value, box, verbs, and which
source said so — that the overlay, the outline and any derived tool read, with `AXPageNode` as the first thing that
fills it. Today the overlay and `outline` read `AXPageNode` directly; generalising that is the first step, and
nothing in the overlay's drawing depends on where a node came from.

**What a derived tool would be.** The shapes are already on main: `WebMCPForms` turns a `<form toolname>` into a tool
whose inputs are its fields. The same, derived rather than declared:

- a form or a `form` / `search` landmark with fields → one tool, its input schema from the fields (name from the
  accessible name, `string` / `boolean` / `number` from the role), its call filling them and pressing the one
  submit control;
- a named control standing alone → a `press` tool, and a settable value → `set`;
- registered in `WebMCPRegistry` beside the page's own, marked as derived and by which source, and never
  `readOnlyHint` — Savoia cannot know what a press does, so every call is asked about, as an unannotated page tool is.
- **A page's own tools win.** Where a page declares tools, derived ones step back or are listed after them: the page
  knows what its buttons mean, and the tree only knows what they are called.

Acting needs hands per source: for this one, `AXUIElementPerformAction` and setting `AXValue`, asked of the same
child over the same pipe — which is why `AXReadRequest` is a request type and not a bare rectangle.

### The mark, as built

Beside `PageToolsButton`, the same wrench with a spark: this page declared no tools, and its tree is good enough to
make some of. The popover lists them — `fill` a form with its fields, `press` a control, `type` into a field — with
"each call by an agent is confirmed" under the title ([below](#offered-to-agents)). Only with WebMCP on (`savoia://configuration`
▸ Develop), never in a private window, never over a page's own tools. `AddressBar` reads the focused window a second
after it stops loading, through the same `AccessibilityOverlay.read` — so it costs one child and ~30–200 ms per
navigation, and puts the web content process into accessibility mode as the overlay does. `get_accessibility_tree`
ends with the same verdict, for an agent and for measuring.

**What counts as good** (`DerivedPageTools`), counting controls and fields and leaving links out — following a link
is navigation, which an agent has already:

- a web area with at least three elements in it — otherwise *no tree*: a PDF, a canvas with nothing inside, a page
  not built yet;
- at least **3** controls and fields — otherwise *too few*: an article, a front page of links, a cookie wall;
- at least **60 %** of them named — otherwise *unnamed*: an agent would be pressing buttons it cannot tell apart.

Chosen on nineteen pages, read on screen at 1440 pt wide, 27 September 2026:

| page | elements | controls and fields | named | verdict |
|---|---|---|---|---|
| example.com | 8 | 0 | 0 | too few |
| Hacker News, front page | 1 097 | 0 | 0 | too few — links only |
| booking.com | 15 | 1 | 1 | too few |
| an arXiv PDF | — | — | — | no tree |
| Wikipedia, *Accessibility* | 156 | 20 | 20 | good |
| GitHub, a repository | 496 | 26 | 23 | good |
| DuckDuckGo | 102 | 7 | 7 | good |
| Google | 78 | 10 | 9 | good — the search form is one tool |
| Excalidraw | 66 | 25 | 24 | good — the toolbar around the canvas |
| Apple's SwiftUI docs | 204 | 25 | 24 | good |
| Stack Overflow, a question | 239 | 11 | 9 | good |
| vc.ru | 151 | 18 | 15 | good |
| Figma's login | 30 | 4 | 4 | good |
| the stand | 32 | 8 | 8 | good |
| YouTube | 101 | 8 | 6 | good at 60 % (75 %) |
| OpenStreetMap | 177 | 10 | 7 | good at 60 % (70 %) |
| Amazon | 290 | 54 | 24 | unnamed (44 %) |
| ya.ru | 54 | 27 | 6 | unnamed (22 %) |

80 % was the first threshold and lost YouTube and OpenStreetMap, where most of what an agent would press does have a
name. Only the visible part is read, so the verdict is about the screen, not the page.

### Used by page tasks

`run_page_task` and `/do` on the ⌘E line ([agent-actions.md](agent-actions.md#run_page_task-the-routes)) are the
first caller. On a page with no WebMCP tools of its own, with WebMCP on and a *good* verdict, each step reads the tree,
and every derived tool's node is matched to the smallest DOM snapshot element whose box holds its middle — the tree
for the eyes, the DOM for the hands. A form is then offered as one `FILL_FORM` step: on the stand's contact form that
is fields, list, consent and send in one step, 4 steps instead of 8. `DerivedPageTools.Tool.fields` carries the field nodes for it.

### Offered to agents

On the same page — no declared tools, WebMCP on, a *good* verdict — `list_page_tools` answers with the derived tools
as `WebMCPTool`s, and `call_page_tool` calls them (`DerivedPageToolCalls`). A form is `fill_<its name>`: a string
per text field, an option's label per list, a boolean per checkbox, and `submit`, which presses its last named
button. Radios are left out — each is named for its option, not for the question. A form with no label of its own is
named after that button, because WebKit names it from all the text inside. A field is `type_…` with `text` and
`submit` (Enter); a control is `press_…`. A node whose middle lands on no element — a checkbox, whose node spans its
label while the `<input>` is the small box at its edge — takes the element it overlaps most. The name is built from the accessible name, so it survives a new read:
every call reads the tree again and finds the tool by name, and a tool that went away fails as `noSuchTool` with
the ones that are there. `FILL_FORM` in `run_page_task` fills through the same `PageTaskRoute.fill`, and there a
submit button whose name commits is not pressed. The call goes through WebMCP's gate with `readOnlyHint` false — Savoia cannot know what a
button does — so the person confirms every one; the answer is what was done and the page's snapshot after it. They
are not in `WebMCPRegistry` and not shown under the wrench: they belong to one reading of the screen, not to the page.

## Not built

- **Acting through the tree.** `AXUIElementPerformAction(AXPress)` and setting `AXValue` press the way VoiceOver
  does; today a derived tool acts through the DOM element under it
  ([agent-actions.md](agent-actions.md#not-built)).
- **Developer ID signing.** Under ad-hoc signing every build is a new code hash and loses the grant ("Signing"
  above); the Release in `/Applications` included.
- **Other fronts.** WebKitGTK exposes the same tree over AT-SPI (D-Bus), so Linux could have this without a
  permission prompt. Windows' WebKit and iOS have no route.
- **Cross-origin iframes** in separate processes (site isolation) appear as remote frames inside the tree; not tested.

## Sources

- [`AXUIElement`](https://developer.apple.com/documentation/applicationservices/axuielement) and
  [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) — the API and the permission check.
- [The Curious Case of the Responsible Process](https://www.qt.io/blog/the-curious-case-of-the-responsible-process) — what "responsible" means, and how a launched process inherits it.
- [Permissions, privacy and TCC](https://eclecticlight.co/2025/11/08/explainer-permissions-privacy-and-tcc/) — how the records are kept and matched.
- [Accessibility Permission in macOS](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html) — including why App Sandbox rules this out entirely (Savoia's is off).
- [The host app appears in Accessibility Permission](https://developer.apple.com/forums/thread/777040) — the report that an extension's own entry can appear; our XPC measurement above is the answer for a service Savoia launches itself.
- [Focus follows mouse deadlocks on a hit test into its own SwiftUI panel](https://github.com/vorssaint/vorssaint-utils/issues/1420) — the same deadlock, found by someone else, with the same conclusion: do not ask yourself.
